#!/usr/bin/env bun
// End-to-end test for Remote Control (the `pigeon` CLI), against a running
// dev instance (`scripts/pigeonctl launch`). Deterministic: no LLM, no real
// coding agent. `cat` stands in for the agent (it owns the pty foreground
// and echoes whatever gets typed), and the hook reports go through the
// real installed reporter script with the tab's real env — the same path
// Claude Code / Codex / pi hooks take.
//
//   bun scripts/remote-e2e.ts
//
// Leaves Remote Control in the state it found it.

import { $ } from "bun";
import { existsSync, mkdtempSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const DRIVER = `http://127.0.0.1:${process.env.PIGEON_DRIVER_PORT ?? "8790"}`;
const REPORTER = join(homedir(), ".config/pigeon/hooks/pigeon-activity");

let failures = 0;
const check = (name: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${!ok && detail ? `\n     ${detail}` : ""}`);
  if (!ok) failures++;
};

const driver = async (method: string, path: string, body?: unknown) => {
  const response = await fetch(DRIVER + path, {
    method,
    // /input/text takes the raw text; everything else JSON.
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function until<T>(what: string, probe: () => Promise<T | undefined>, ms = 8000): Promise<T> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const value = await probe();
    if (value !== undefined) return value;
    await sleep(200);
  }
  throw new Error(`timed out waiting for ${what}`);
}

// --- setup ---------------------------------------------------------------

const initial = await driver("GET", "/remote/state").catch(() => null);
if (!initial || typeof initial !== "object") {
  console.error("Pigeon dev instance not reachable — run scripts/pigeonctl launch first");
  process.exit(2);
}
const wasEnabled: boolean = initial.enabled;
await driver("POST", "/remote/enable", { enabled: true });
const state = await driver("GET", "/remote/state");
const CLI: string = state.cli;

type CLIResult = { code: number; out: string; err: string };
const pigeon = async (...args: string[]): Promise<CLIResult> => {
  const result = await $`${CLI} ${args}`.nothrow().quiet();
  return { code: result.exitCode, out: result.stdout.toString(), err: result.stderr.toString() };
};
const pigeonJSON = async (...args: string[]) => JSON.parse((await pigeon(...args, "--json")).out);

const info = await driver("GET", "/agent/info");
const tabID: string = (await driver("POST", "/tabs/new")).id;
const tab = async () =>
  (await driver("GET", "/state")).tabs.find((t: any) => t.id === tabID);
const surface: string = (await tab()).surface;
const shortID = tabID.toLowerCase().slice(0, 8);
const hookEnv = {
  ...process.env,
  PIGEON_AGENT_PORT: String(info.port),
  PIGEON_AGENT_TOKEN: info.token,
  PIGEON_SURFACE_ID: surface,
};

/** Fire the installed reporter script exactly like a host hook would. */
const hook = (event: string, source: string, input: unknown) => {
  const child = Bun.spawn([REPORTER, event, source], {
    env: hookEnv,
    stdin: new Blob([JSON.stringify(input)]),
    stdout: "pipe",
  });
  return {
    child,
    output: (async () => {
      await child.exited;
      return await new Response(child.stdout).text();
    })(),
  };
};

const screen = async () => (await pigeon("screen", shortID, "--lines", "40")).out;

try {
  // The stand-in agent: owns the pty foreground, echoes typed lines.
  await sleep(1200); // shell prompt
  await driver("POST", "/tabs/select", { id: tabID });
  await driver("POST", "/input/text", "cat");
  await driver("POST", "/input/key", { key: "enter" });
  await sleep(500);

  // --- transport ------------------------------------------------------------
  const sock = statSync(state.socket);
  check("socket is 0600", (sock.mode & 0o777) === 0o600, (sock.mode & 0o777).toString(8));
  check("help", (await pigeon("help")).out.includes("pigeon sessions"));
  check("unknown command fails", (await pigeon("frobnicate")).code === 1);

  // --- session lifecycle ------------------------------------------------------
  const before = await pigeonJSON("events");
  await hook("ping", "claude-code", { hook_event_name: "SessionStart", source: "startup" }).output;
  let sessions = await pigeonJSON("sessions");
  let mine = sessions.sessions.find((s: any) => s.id === shortID);
  check("ping creates a session", mine?.agent === "claude-code" && mine?.state === "idle",
    JSON.stringify(mine));
  check("session can be messaged while its agent is in front", mine?.can_send === true);

  const sent = await pigeon("send", shortID, "hello-e2e-42");
  check("send succeeds", sent.code === 0, sent.out + sent.err);
  await until("echo of sent text", async () =>
    (await screen()).split("hello-e2e-42").length >= 3 ? true : undefined);
  check("send types the text and presses Enter (cat echoed it)", true);

  await hook("busy", "claude-code", { hook_event_name: "UserPromptSubmit", prompt: "fix the build" }).output;
  check("busy → working", (await pigeonJSON("sessions")).sessions
    .find((s: any) => s.id === shortID)?.state === "working");
  await hook("idle", "claude-code", {
    hook_event_name: "Stop", stop_hook_active: false,
    last_assistant_message: "Fixed it.\nThe build passes now.", nullable: null,
  }).output;
  const shown = await pigeonJSON("show", shortID);
  const last = shown.exchanges.at(-1);
  check("Stop's last_assistant_message is recorded as the reply",
    last?.prompt === "fix the build" && last?.reply === "Fixed it.\nThe build passes now.",
    JSON.stringify(last));
  check("show text has the full reply", (await pigeon("show", shortID)).out.includes("The build passes now."));

  const events = await pigeonJSON("events", "--since", String(before.cursor), "--wait", "0");
  const kinds = events.events.filter((e: any) => e.session === shortID).map((e: any) => e.kind);
  check("events: started, working, finished", JSON.stringify(kinds) === '["started","working","finished"]',
    JSON.stringify(kinds));

  // Long-poll returns as soon as something happens.
  const cursor = (await pigeonJSON("events", "--since", "0", "--wait", "0")).cursor;
  const waiting = pigeonJSON("events", "--since", String(cursor), "--wait", "20");
  await sleep(500);
  const t0 = Date.now();
  await hook("busy", "claude-code", { hook_event_name: "UserPromptSubmit", prompt: "second" }).output;
  const woke = await waiting;
  check("events --wait wakes on a new event", woke.events.length >= 1 && Date.now() - t0 < 3000);
  await hook("idle", "claude-code", { hook_event_name: "Stop" }).output;
  const quiet = await pigeon("events", "--since", String((await pigeonJSON("events")).cursor), "--wait", "1");
  check("events --wait times out quietly", quiet.out.includes("No new events in 1s"), quiet.out);

  // --- attention -------------------------------------------------------------
  await hook("attention", "claude-code", {
    hook_event_name: "Notification", notification_type: "idle_prompt", message: "Claude is waiting",
  }).output;
  check("passive notifications don't block", (await pigeonJSON("sessions")).sessions
    .find((s: any) => s.id === shortID)?.state === "idle");
  await hook("attention", "claude-code", {
    hook_event_name: "Notification", notification_type: "elicitation_dialog", message: "Pick a database",
  }).output;
  mine = (await pigeonJSON("sessions")).sessions.find((s: any) => s.id === shortID);
  check("blocking notification → needs_input", mine?.state === "needs_input" && mine?.waiting_for === "Pick a database");
  check("send refused while the agent waits on a prompt", (await pigeon("send", shortID, "x")).code === 1);
  await hook("busy", "claude-code", { hook_event_name: "UserPromptSubmit" }).output;
  await hook("idle", "claude-code", { hook_event_name: "Stop" }).output;
  check("next turn clears needs_input", (await pigeonJSON("sessions")).sessions
    .find((s: any) => s.id === shortID)?.state === "idle");

  // --- approvals ---------------------------------------------------------------
  let held = hook("permission", "codex", {
    hook_event_name: "PermissionRequest", tool_name: "Bash",
    tool_input: { command: "rm -rf build", description: null },
  });
  const pending = await until("pending approval", async () => {
    const list = (await pigeonJSON("approvals")).approvals;
    return list.length ? list[0] : undefined;
  });
  check("held request is listed", pending.tool === "Bash" && pending.summary === "rm -rf build"
    && pending.session === shortID, JSON.stringify(pending));
  check("session shows awaiting_approval", (await pigeonJSON("sessions")).sessions
    .find((s: any) => s.id === shortID)?.state === "awaiting_approval");
  check("send refused while an approval is pending", (await pigeon("send", shortID, "x")).code === 1);
  check("approve unknown id fails", (await pigeon("approve", "pzzzzz")).code === 1);
  check("approve", (await pigeon("approve", pending.id)).code === 0);
  check("hook prints the allow decision", JSON.parse(await held.output).hookSpecificOutput
    ?.decision?.behavior === "allow");
  check("double answer fails", (await pigeon("deny", pending.id)).code === 1);

  held = hook("permission", "claude-code", { tool_name: "Write", tool_input: { file_path: "/etc/x" } });
  const second = await until("second approval", async () =>
    (await pigeonJSON("approvals")).approvals[0]);
  await pigeon("deny", second.id, "not", "now");
  const denial = JSON.parse(await held.output).hookSpecificOutput?.decision;
  check("deny carries the reason to the agent", denial?.behavior === "deny"
    && denial?.message?.includes("not now"), JSON.stringify(denial));

  held = hook("permission", "codex", { tool_name: "Bash", tool_input: { command: "sleep 1" } });
  await until("third approval", async () => (await pigeonJSON("approvals")).approvals[0]);
  // The host killed its hook (answered locally / Esc). Hosts take down
  // the whole hook process tree; here that is the script and its curl.
  held.child.kill();
  await $`pkill -f ${`127.0.0.1:${info.port}/permission`}`.nothrow().quiet();
  await until("withdrawal", async () =>
    (await pigeonJSON("approvals")).approvals.length === 0 ? true : undefined);
  check("killed hook withdraws its request", true);

  // Banner path (driver resolves as the in-tab buttons do).
  held = hook("permission", "codex", { tool_name: "Bash", tool_input: { command: "make" } });
  const fourth = await until("fourth approval", async () => (await pigeonJSON("approvals")).approvals[0]);
  await driver("POST", "/remote/resolve", { id: fourth.id, decision: "release" });
  check("release prints nothing (agent's own prompt decides)", (await held.output) === "");

  // --- guards ------------------------------------------------------------------
  // Inside a Pigeon terminal: read-only works, mutations are refused.
  const other: string = (await driver("POST", "/tabs/new")).id;
  await sleep(1200);
  await driver("POST", "/input/text", `${CLI} approve p00000; ${CLI} sessions | head -1`);
  await driver("POST", "/input/key", { key: "enter" });
  const insideText = await until("inside-Pigeon output", async () => {
    const text = await driver("GET", `/text?id=${other}`);
    return typeof text === "string" && text.includes("agent session") ? text : undefined;
  });
  check("mutations refused from inside a Pigeon terminal", insideText.includes("refused: this command was run from inside a Pigeon terminal"));
  check("read-only allowed from inside", insideText.includes("agent session"));
  await driver("POST", "/tabs/close", { id: other });

  // Agent gone without a final hook: the shell is in front again.
  // Kill the stand-in agent outright, like a crash: no final hook. (The
  // driver's ctrl keys leak as CSI-u, so no ctrl-d here.)
  const agentGroup = (await driver("GET", "/remote/state")).sessions[surface].agentProcessGroup;
  process.kill(-agentGroup, "SIGKILL");
  await until("cat exited", async () => {
    const s = (await driver("GET", "/remote/state")).sessions[surface];
    return s && s.foregroundProcessGroup !== s.agentProcessGroup ? true : undefined;
  });
  const refused = await pigeon("send", shortID, "echo SHOULD-NOT-RUN");
  check("send refused once the agent left the foreground", refused.code === 1
    && refused.out.includes("no longer in the foreground"), refused.out);
  check("sessions flags it", (await pigeonJSON("sessions")).sessions
    .find((s: any) => s.id === shortID)?.can_send === false);
  check("shell never received the text", !(await screen()).includes("SHOULD-NOT-RUN"));

  await hook("idle", "claude-code", { hook_event_name: "SessionEnd" }).output;
  check("SessionEnd ends the session", !(await pigeonJSON("sessions")).sessions
    .some((s: any) => s.id === shortID));

  // A hook fired while the shell itself is in front (a headless agent
  // run in the background) must not make the shell typeable.
  await hook("ping", "claude-code", { hook_event_name: "SessionStart" }).output;
  mine = (await pigeonJSON("sessions")).sessions.find((s: any) => s.id === shortID);
  check("hook with the shell in front: session listed but not messageable",
    mine?.state === "idle" && mine?.can_send === false, JSON.stringify(mine));
  const shellRefused = await pigeon("send", shortID, "echo SHOULD-NOT-RUN-2");
  check("send refused when the shell is in front", shellRefused.code === 1, shellRefused.out);
  check("key refused when the shell is in front", (await pigeon("key", shortID, "enter")).code === 1);
  check("shell never received it", !(await screen()).includes("SHOULD-NOT-RUN-2"));
  await hook("idle", "claude-code", { hook_event_name: "SessionEnd" }).output;

  // `new` validates its input before opening anything.
  check("new rejects unknown agents", (await pigeon("new", tmpdir(), "bash")).code === 1);
  check("new rejects missing directories", (await pigeon("new", "/no/such/dir", "pi")).code === 1);

  // --- off -----------------------------------------------------------------------
  await driver("POST", "/remote/enable", { enabled: false });
  const t1 = Date.now();
  const passThrough = await hook("permission", "codex", { tool_name: "Bash", tool_input: { command: "ls" } }).output;
  check("remote off: permission hook returns at once with no decision",
    passThrough === "" && Date.now() - t1 < 2000);
  const off = await pigeon("sessions");
  check("remote off: CLI explains and exits 69", off.code === 69 && off.err.includes("Remote Control is off"));
  check("remote off: socket removed", !existsSync(state.socket));
} catch (error) {
  failures++;
  console.log(`FAIL ${(error as Error).message}`);
} finally {
  await driver("POST", "/tabs/close", { id: tabID }).catch(() => {});
  await driver("POST", "/remote/enable", { enabled: wasEnabled }).catch(() => {});
}

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
