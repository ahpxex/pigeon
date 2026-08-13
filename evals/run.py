#!/usr/bin/env python3
"""Pigeon agent eval runner.

Drives the REAL agent path: cases POST to the in-app AgentServer /ask
(bearer token fetched via the driver), so the loop, tools, markdown
rendering and auth all run exactly as in production. Two kinds of suite:

  regression (deterministic)   cases carry scripted mock-LLM turns; the
                               runner spawns evals/mock_llm.py and points
                               Pigeon at it. No network, no keys, stable.
  live (quality)               cases have no turns; they run against a
                               real provider already configured in Pigeon.

Usage:
    python3 evals/run.py                          # regression suite
    python3 evals/run.py --suite evals/cases/live.json \
        --live --provider DeepSeek [--model deepseek-chat]
    python3 evals/run.py --verbose               # dump output of failures

Prereq: the app is running under the driver (scripts/pigeonctl launch).
Every run also executes a fixed security preflight asserting the /ask
auth red lines (missing/wrong token, browser Origin ⇒ 403).

Case schema (JSON, see evals/cases/*.json):
    name         unique id; also the mock scenario match key via `prompt`
    prompt       what the "user typed"
    turns        (regression only) scripted assistant turns for mock_llm
    fixture      {"filename": "content", "subdir/": null} — temp cwd
    confirm      "allow" | "deny" (default) — answer to confirmation
                 requests from mutating tools; they appear in the text as
                 "[confirm-request] <display>"
    expect       list of checks:
        {"type": "contains",      "value": str}      on ANSI-stripped text
        {"type": "not_contains",  "value": str}
        {"type": "regex",         "value": pattern}
        {"type": "raw_contains",  "value": str}      on raw ANSI output
        {"type": "count",         "value": str, "n": int}
        {"type": "tool_used",     "value": tool-name} (⏺ line present)
        {"type": "max_lines",     "n": int}           non-empty answer lines
        {"type": "max_seconds",   "n": float}
        {"type": "no_error"}                          no "pigeon:" error line
        {"type": "fixture_exists", "value": path, "contains"?: str}
        {"type": "fixture_missing", "value": path}    checked before cleanup
"""

import argparse
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

DRIVER_PORT = int(os.environ.get("PIGEON_DRIVER_PORT", "8790"))
ANSI_RE = re.compile(r"\x1b(?:\[[0-9;]*[A-Za-z]|\]8;;[^\x07\x1b]*(?:\x07|\x1b\\))")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


# ---------------------------------------------------------------- driver

def driver(method, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", DRIVER_PORT, timeout=10)
    payload = json.dumps(body) if body is not None else None
    conn.request(method, path, body=payload)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    if response.status != 200:
        raise RuntimeError(f"driver {method} {path}: HTTP {response.status} {data[:200]}")
    return json.loads(data) if data else {}


CONFIRM_SENTINEL = b"\x01PIGEON_CONFIRM\x01"


def ask(agent_port, token, prompt, cwd, timeout, host=None, origin=None,
        omit_auth=False, confirm="deny"):
    """POST /ask exactly like the shell hook does; returns (status, raw).

    Streams the response line by line so confirmation sentinels can be
    answered mid-flight (like the zsh hook does): `confirm` is "allow" or
    "deny". Sentinel lines are replaced by "[confirm-request] <display>"
    in the returned text so cases can assert on them.
    """
    conn = http.client.HTTPConnection("127.0.0.1", agent_port, timeout=timeout)
    conn.putrequest("POST", "/ask", skip_host=True)
    conn.putheader("Host", host or f"127.0.0.1:{agent_port}")
    if not omit_auth:
        conn.putheader("Authorization", f"Bearer {token}")
    if origin:
        conn.putheader("Origin", origin)
    conn.putheader("X-Pigeon-Cwd", cwd)
    body = prompt.encode()
    conn.putheader("Content-Length", str(len(body)))
    conn.endheaders()
    conn.send(body)
    response = conn.getresponse()
    if response.status != 200:
        raw = response.read().decode(errors="replace")
        conn.close()
        return response.status, raw

    parts, buf = [], b""
    while True:
        byte = response.read(1)
        if not byte:
            break
        buf += byte
        if byte != b"\n":
            continue
        line, buf = buf, b""
        if line.startswith(CONFIRM_SENTINEL):
            fields = line.decode(errors="replace").rstrip("\n").split("\x01")
            confirm_id = fields[2] if len(fields) > 2 else ""
            display = fields[3] if len(fields) > 3 else ""
            parts.append(f"[confirm-request] {display}\n".encode())
            post_confirm(agent_port, token, confirm_id, confirm == "allow")
        else:
            parts.append(line)
    if buf:
        parts.append(buf)
    conn.close()
    return 200, b"".join(parts).decode(errors="replace")


def post_confirm(agent_port, token, confirm_id, allow):
    conn = http.client.HTTPConnection("127.0.0.1", agent_port, timeout=10)
    payload = json.dumps({"id": confirm_id, "allow": allow})
    conn.request("POST", "/confirm", body=payload,
                 headers={"Authorization": f"Bearer {token}"})
    conn.getresponse().read()
    conn.close()


# ---------------------------------------------------------------- checks

def run_checks(case, raw, seconds, cwd):
    text = strip_ansi(raw)
    failures = []
    for check in case.get("expect", []):
        kind = check["type"]
        value = check.get("value", "")
        ok = True
        if kind == "contains":
            ok = value in text
        elif kind == "not_contains":
            ok = value not in text
        elif kind == "regex":
            ok = re.search(value, text) is not None
        elif kind == "raw_contains":
            ok = value in raw
        elif kind == "raw_not_contains":
            ok = value not in raw
        elif kind == "count":
            ok = text.count(value) == check["n"]
        elif kind == "tool_used":
            ok = f"⏺ {value}" in text
        elif kind == "max_lines":
            lines = [l for l in text.splitlines() if l.strip() and not l.startswith("⏺")]
            ok = len(lines) <= check["n"]
        elif kind == "max_seconds":
            ok = seconds <= check["n"]
        elif kind == "no_error":
            ok = "pigeon:" not in text
        elif kind == "fixture_exists":
            path = os.path.join(cwd, value)
            ok = os.path.isfile(path)
            if ok and check.get("contains"):
                with open(path) as f:
                    ok = check["contains"] in f.read()
        elif kind == "fixture_missing":
            ok = not os.path.exists(os.path.join(cwd, value))
        else:
            ok = False
            value = f"unknown check type {kind!r}"
        if not ok:
            failures.append(f"{kind}: {value!r}" + (f" n={check.get('n')}" if "n" in check else ""))
    return failures


# ------------------------------------------------------------- fixtures

def build_fixture(spec):
    root = tempfile.mkdtemp(prefix="pigeon-eval-")
    for name, content in (spec or {}).items():
        path = os.path.join(root, name)
        if name.endswith("/"):
            os.makedirs(path, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(content, dict):  # {"repeat": "x", "n": 5000}
            content = content["repeat"] * content["n"]
        with open(path, "w") as f:
            f.write(content or "")
    return root


# ------------------------------------------------------------- security

def security_preflight(agent_port, token):
    """The /ask auth red lines, asserted on every run."""
    probes = [
        ("no token", dict(omit_auth=True)),
        ("wrong token", dict()),  # token replaced below
        ("browser origin", dict(origin="https://evil.example")),
        ("dns-rebinding host", dict(host="pigeon.evil.example:80")),
    ]
    failures = []
    for name, kwargs in probes:
        use_token = "0" * 64 if name == "wrong token" else token
        try:
            status, _ = ask(agent_port, use_token, "ping", "/tmp", 10, **kwargs)
        except Exception as e:  # noqa: BLE001
            failures.append(f"{name}: request error {e}")
            continue
        if status != 403:
            failures.append(f"{name}: expected 403, got {status}")

    # /confirm shares the same auth rules — an unauthenticated confirm
    # would let any local process approve mutations.
    try:
        conn = http.client.HTTPConnection("127.0.0.1", agent_port, timeout=10)
        conn.request("POST", "/confirm", body='{"id":"x","allow":true}')
        status = conn.getresponse().status
        conn.close()
        if status != 403:
            failures.append(f"unauthenticated /confirm: expected 403, got {status}")
    except Exception as e:  # noqa: BLE001
        failures.append(f"unauthenticated /confirm: request error {e}")
    return failures


# ------------------------------------------------------------------ main

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", default=os.path.join(os.path.dirname(__file__), "cases/regression.json"))
    parser.add_argument("--live", action="store_true",
                        help="run cases without scripted turns against a real provider")
    parser.add_argument("--provider", default="DeepSeek", help="provider name in Pigeon settings")
    parser.add_argument("--model", default="", help="override the provider's selected model")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--verbose", action="store_true", help="dump output for failed cases")
    parser.add_argument("--only", default="", help="run only cases whose name contains this")
    args = parser.parse_args()

    with open(args.suite) as f:
        cases = json.load(f)
    if args.only:
        cases = [c for c in cases if args.only in c["name"]]

    mock_cases = [c for c in cases if "turns" in c]
    live_cases = [c for c in cases if "turns" not in c]
    if live_cases and not args.live:
        print(f"note: skipping {len(live_cases)} live case(s) — pass --live to run them")
        live_cases = []

    info = driver("GET", "/agent/info")
    agent_port, token = info["port"], info["token"]
    saved_provider, saved_model = info.get("defaultProvider"), info.get("defaultModel")

    print("== security preflight ==")
    sec_failures = security_preflight(agent_port, token)
    for failure in sec_failures:
        print(f"  FAIL {failure}")
    if not sec_failures:
        print("  PASS /ask rejects unauthenticated, wrong-token, origin, host probes")

    results = []  # (name, seconds, failures, raw)
    mock_process = None
    try:
        if mock_cases:
            mock_port = _free_port()
            scenarios = [{"match": c["prompt"], "turns": c["turns"]} for c in mock_cases]
            scenario_file = tempfile.NamedTemporaryFile(
                "w", suffix=".json", delete=False)
            json.dump(scenarios, scenario_file)
            scenario_file.close()
            mock_process = subprocess.Popen(
                [sys.executable, os.path.join(os.path.dirname(__file__), "mock_llm.py"),
                 "--port", str(mock_port), "--scenarios", scenario_file.name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            _wait_port(mock_port)
            driver("POST", "/agent/provider", {
                "name": "PigeonEvalMock",
                "baseURL": f"http://127.0.0.1:{mock_port}/v1",
                "model": "mock-1",
                "apiKey": "eval",
            })
            print(f"\n== regression ({len(mock_cases)} cases, mock llm :{mock_port}) ==")
            results += run_cases(mock_cases, agent_port, token, args)

        if live_cases:
            driver("POST", "/agent/default",
                   {"name": args.provider, "model": args.model})
            print(f"\n== live ({len(live_cases)} cases, {args.provider}"
                  + (f"/{args.model}" if args.model else "") + ") ==")
            results += run_cases(live_cases, agent_port, token, args)
    finally:
        if mock_process:
            mock_process.terminate()
            try:
                driver("POST", "/agent/provider/remove", {"name": "PigeonEvalMock"})
            except Exception:  # noqa: BLE001
                pass
        if saved_provider:
            try:
                driver("POST", "/agent/default",
                       {"name": saved_provider, "model": saved_model or ""})
            except Exception:  # noqa: BLE001
                pass

    failed = [r for r in results if r[2]]
    print(f"\n== summary: {len(results) - len(failed)}/{len(results)} cases passed"
          + (", security preflight FAILED" if sec_failures else "") + " ==")
    if args.verbose:
        for name, _, failures, raw in failed:
            print(f"\n--- {name} output ---\n{strip_ansi(raw)}\n---")
    sys.exit(1 if failed or sec_failures else 0)


def run_cases(cases, agent_port, token, args):
    results = []
    for case in cases:
        cwd = build_fixture(case.get("fixture")) if "fixture" in case else os.path.expanduser("~")
        started = time.monotonic()
        try:
            status, raw = ask(agent_port, token, case["prompt"], cwd, args.timeout,
                              confirm=case.get("confirm", "deny"))
            seconds = time.monotonic() - started
            failures = ([f"HTTP {status}"] if status != 200 else
                        run_checks(case, raw, seconds, cwd))
        except Exception as e:  # noqa: BLE001
            seconds = time.monotonic() - started
            raw, failures = "", [f"request error: {e}"]
        finally:
            if "fixture" in case:
                shutil.rmtree(cwd, ignore_errors=True)
        mark = "PASS" if not failures else "FAIL"
        print(f"  {mark} {case['name']} ({seconds:.1f}s)")
        for failure in failures:
            print(f"       ✗ {failure}")
        results.append((case["name"], seconds, failures, raw))
    return results


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_port(port, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"mock llm did not come up on :{port}")


if __name__ == "__main__":
    main()
