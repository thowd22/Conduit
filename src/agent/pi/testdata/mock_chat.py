# A local mock OpenAI Chat Completions endpoint for the Pi adapter's
# integration test (TASK-55). It binds 127.0.0.1 on an ephemeral port, prints
# that port on stdout, and answers every streamed request: when a user message
# contains RUNTOOL and the conversation does not end with a tool result, a
# single `bash` tool call running `touch probe_file`; otherwise the text
# MOCK_OK. Loopback only, no credentials, request bodies are never logged.
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.end_headers()
            return
        messages = body.get("messages", [])
        roles = [m.get("role") for m in messages]
        wants = any("RUNTOOL" in json.dumps(m.get("content")) for m in messages if m.get("role") == "user")
        base = {"id": "mock", "object": "chat.completion.chunk", "model": "mock-model"}
        if wants and roles and roles[-1] != "tool":
            delta = {
                "role": "assistant",
                "tool_calls": [{
                    "index": 0,
                    "id": "call_probe",
                    "type": "function",
                    "function": {"name": "bash", "arguments": json.dumps({"command": "touch probe_file"})},
                }],
            }
            finish = "tool_calls"
        else:
            delta = {"role": "assistant", "content": "MOCK_OK"}
            finish = "stop"
        chunks = [
            dict(base, choices=[{"index": 0, "delta": delta, "finish_reason": None}]),
            dict(base, choices=[{"index": 0, "delta": {}, "finish_reason": finish}],
                 usage={"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}),
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("%d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
