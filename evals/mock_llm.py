#!/usr/bin/env python3
"""Mock OpenAI-compatible /chat/completions SSE server for Pigeon agent tests.

Deterministic stand-in for a real provider: scenarios map a prompt substring
to a scripted sequence of assistant turns. Turn N of a scenario answers the
Nth round of the agent loop (rounds are counted by how many assistant
messages the request already carries), so multi-round tool flows replay
exactly.

Usage:
    python3 mock_llm.py --port 8977 [--scenarios scenarios.json]

Scenario file format (JSON):
    [
      {
        "match": "substring of the user prompt",
        "turns": [
          {"text": "final answer"},
          {"tool_calls": [{"name": "list_dir", "arguments": {"path": "."}}]}
        ]
      }
    ]

Without --scenarios a built-in demo set is served (markdown showcase etc.).
A turn may carry both "text" and "tool_calls". Unmatched prompts get a
fixed fallback answer so tests fail loudly rather than hang.
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEMO_SCENARIOS = [
    {
        "match": "markdown showcase",
        "turns": [
            {
                "text": (
                    "# Heading One\n"
                    "## Heading Two\n"
                    "Regular text with **bold**, *italic*, `inline code`, "
                    "and a [link](https://example.com).\n"
                    "\n"
                    "- first bullet with **bold**\n"
                    "- second bullet with `code`\n"
                    "1. numbered item\n"
                    "2. another item\n"
                    "\n"
                    "> a blockquote line\n"
                    "\n"
                    "```sh\n"
                    "ls -la | wc -l\n"
                    "```\n"
                    "\n"
                    "---\n"
                    "Done.\n"
                )
            }
        ],
    },
    {
        "match": "tool roundtrip",
        "turns": [
            {"tool_calls": [{"name": "list_dir", "arguments": {"path": "."}}]},
            {"text": "The directory contains **files**; see `above`.\n"},
        ],
    },
]


class Handler(BaseHTTPRequestHandler):
    scenarios = DEMO_SCENARIOS
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet
        pass

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        request = json.loads(self.rfile.read(length))
        messages = request.get("messages", [])

        prompt = next(
            (m.get("content") or "" for m in messages if m.get("role") == "user"), "")
        assistant_rounds = sum(1 for m in messages if m.get("role") == "assistant")

        turn = self.pick_turn(prompt, assistant_rounds)
        self.stream_turn(turn)

    def pick_turn(self, prompt, round_index):
        for scenario in self.scenarios:
            if scenario["match"] in prompt:
                turns = scenario["turns"]
                if round_index < len(turns):
                    return turns[round_index]
                return {"text": "mock: scenario ran out of turns\n"}
        return {"text": "mock: no scenario matched this prompt\n"}

    def stream_turn(self, turn):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def sse(payload):
            data = "data: " + json.dumps(payload) + "\n\n"
            raw = data.encode()
            self.wfile.write(f"{len(raw):X}\r\n".encode() + raw + b"\r\n")
            self.wfile.flush()

        def delta(d, finish=None):
            sse({"choices": [{"delta": d, "finish_reason": finish}]})

        text = turn.get("text")
        if text:
            # Deliberately small, unaligned chunks: exercises the streaming
            # renderer against markdown tokens split across deltas.
            for i in range(0, len(text), 7):
                delta({"content": text[i : i + 7]})
                time.sleep(0.005)

        calls = turn.get("tool_calls", [])
        for index, call in enumerate(calls):
            delta({
                "tool_calls": [{
                    "index": index,
                    "id": f"call_{index}",
                    "function": {
                        "name": call["name"],
                        "arguments": json.dumps(call.get("arguments", {})),
                    },
                }]
            })

        delta({}, finish="tool_calls" if calls else "stop")
        raw = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(raw):X}\r\n".encode() + raw + b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8977)
    parser.add_argument("--scenarios", help="path to scenarios JSON")
    args = parser.parse_args()

    if args.scenarios:
        with open(args.scenarios) as f:
            Handler.scenarios = json.load(f)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock llm on 127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
