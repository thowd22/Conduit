#!/usr/bin/env python3
"""A fixed OpenAI-compatible chat model for scripts/opencode-container-check.sh.

OpenCode talks to it as a custom provider (`@ai-sdk/openai-compatible`), so a
real `opencode` runs real turns with no network model and no credentials. The
answers are fixed, which is what makes the live check deterministic:

- a request without tools (OpenCode's title and summary calls) gets a short
  text answer;
- a request whose last message is a tool result gets "All done." and stops;
- any other request calls the `bash` tool once with `echo conduit-live`,
  which OpenCode's `permission.bash = "ask"` turns into a permission request.

Only loopback is served. Every request is appended to the log named by
`--log`, so the transcript shows what OpenCode actually sent.
"""

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOL_COMMAND = "echo conduit-live"


def chunk(delta, finish=None):
    return {
        "id": "chatcmpl-conduit",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": "conduit-mock",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def answer_for(request):
    messages = request.get("messages") or []
    tools = request.get("tools") or []
    if not tools:
        return "text", "Conduit live check"
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        return "text", "All done."
    return "tool", TOOL_COMMAND


class Handler(BaseHTTPRequestHandler):
    log_path = None

    def log_message(self, fmt, *args):  # quiet the default stderr log
        pass

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({"object": "list", "data": [{"id": "conduit-mock", "object": "model"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            request = {}
        kind, payload = answer_for(request)
        if self.log_path:
            with open(self.log_path, "a", encoding="utf-8") as log:
                roles = [m.get("role") for m in request.get("messages") or []]
                log.write(json.dumps({"path": self.path, "tools": len(request.get("tools") or []), "roles": roles, "answer": kind}) + "\n")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.send_error(404)
            return
        if not request.get("stream"):
            message = {"role": "assistant", "content": payload if kind == "text" else None}
            finish = "stop"
            if kind == "tool":
                message["tool_calls"] = [self.tool_call()]
                finish = "tool_calls"
            body = json.dumps({
                "id": "chatcmpl-conduit", "object": "chat.completion", "created": int(time.time()),
                "model": "conduit-mock",
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        events = [chunk({"role": "assistant", "content": ""})]
        if kind == "text":
            events.append(chunk({"content": payload}))
            events.append(chunk({}, "stop"))
        else:
            call = self.tool_call()
            call["index"] = 0
            events.append(chunk({"tool_calls": [call]}))
            events.append(chunk({}, "tool_calls"))
        usage = chunk({})
        usage["choices"] = []
        usage["usage"] = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
        events.append(usage)
        for item in events:
            self.wfile.write(b"data: " + json.dumps(item).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    @staticmethod
    def tool_call():
        return {
            "id": "call_conduit_1",
            "type": "function",
            "function": {
                "name": "bash",
                "arguments": json.dumps({"command": TOOL_COMMAND, "description": "Print a marker"}),
            },
        }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log")
    args = parser.parse_args()
    Handler.log_path = args.log
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock provider on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
