"""OpenAI-compatible stand-in model for tests that need tool calls but no real
model. Each chat request with tools gets the next step of <dir>/script.json: a
tool call {"tool": "shell", "args": {...}} or text {"text": "..."}; when the
script is empty it answers "done", which ends the turn. Requests without tools
(session titles) get plain text.
Usage: stub-model.py <dir>   (writes the port it listens on to <dir>/port)
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]


def next_step():
    path = os.path.join(DIR, "script.json")
    steps = json.load(open(path)) if os.path.exists(path) else []
    if not steps:
        return {"text": "done"}
    json.dump(steps[1:], open(path, "w"))
    return steps[0]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send(200, json.dumps({"data": [{"id": "stub", "object": "model"}]}).encode())

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        step = next_step() if req.get("tools") else {"text": "stub"}
        if "tool" in step:
            call = {"index": 0, "id": f"call_{time.time_ns()}", "type": "function",
                    "function": {"name": step["tool"], "arguments": json.dumps(step["args"])}}
            message, finish = {"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls"
        else:
            message, finish = {"role": "assistant", "content": step["text"]}, "stop"
        # cost: the charge, as OpenRouter's usage accounting reports it.
        usage = {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2, "cost": 0.01}
        if not req.get("stream"):
            self.send(200, json.dumps({"id": "stub", "object": "chat.completion", "created": 0, "model": "stub",
                                       "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                                       "usage": usage}).encode())
            return
        chunks = [{"choices": [{"index": 0, "delta": message, "finish_reason": None}]},
                  {"choices": [{"index": 0, "delta": {}, "finish_reason": finish}]},
                  {"choices": [], "usage": usage}]
        body = b"".join(b"data: " + json.dumps({"id": "stub", "object": "chat.completion.chunk", "created": 0,
                                                "model": "stub", **c}).encode() + b"\n\n" for c in chunks)
        self.send(200, body + b"data: [DONE]\n\n", "text/event-stream")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
