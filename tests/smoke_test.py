"""End-to-end smoke test for the multitool bridge via MCP stdio protocol.

Sends MCP JSON-RPC messages to the bridge process and verifies responses.
Requires the sbcl-multitool Docker image to be built.
"""
import json
import subprocess
import sys
import os
import time

BRIDGE = [os.path.join(os.path.dirname(__file__), "..", ".venv", "bin", "python3"), "-m", "bridge"]


class MCPClient:
    def __init__(self):
        self.proc = subprocess.Popen(
            BRIDGE, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
            cwd=os.path.join(os.path.dirname(__file__), ".."),
        )
        self._id = 0

    def _send(self, method, params=None, notification=False):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            msg["params"] = params
        if notification:
            del msg["id"]
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if notification:
            return None
        line = self.proc.stdout.readline()
        return json.loads(line)

    def initialize(self):
        return self._send("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1.0"},
        })

    def initialized(self):
        self._send("notifications/initialized", notification=True)

    def call_tool(self, name, arguments):
        return self._send("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


def extract_json(text):
    return json.loads(text)


def test():
    client = MCPClient()
    failures = []
    checks = []

    def check(name, condition, detail=""):
        status = "PASS" if condition else "FAIL"
        checks.append((status, name))
        if not condition:
            failures.append(f"{name}: {detail}")

    init = client.initialize()
    check("initialize", init.get("result", {}).get("serverInfo", {}).get("name") == "multitool-sbcl",
          str(init))
    client.initialized()

    # 1. eval
    r = client.call_tool("lisp_eval", {"form": "(+ 1 2)"})
    data = extract_json(r["result"]["content"][0]["text"])
    check("eval (+ 1 2)", data["ok"] is True and data["result"]["values"] == ["3"], str(data))

    # 2. persistence
    r1 = client.call_tool("lisp_eval", {"form": "(defun cube (x) (* x x x))"})
    r2 = client.call_tool("lisp_eval", {"form": "(cube 3)"})
    d2 = extract_json(r2["result"]["content"][0]["text"])
    check("persistence (defun + call)", d2["ok"] is True and d2["result"]["values"] == ["27"], str(d2))

    # 3. stdout capture
    r = client.call_tool("lisp_eval", {"form": '(format t "hello~%")'})
    d = extract_json(r["result"]["content"][0]["text"])
    check("stdout capture", d["result"]["stdout"] == "hello\n", str(d))

    # 4. multiple values
    r = client.call_tool("lisp_eval", {"form": "(values 1 2 3)"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("multiple values", d["result"]["values"] == ["1", "2", "3"], str(d))

    # 5. introspect symbol
    r = client.call_tool("lisp_introspect", {"what": "symbol", "name": "CL:LIST"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("introspect symbol", d["ok"] is True and d["result"]["fboundp"] is True, str(d))

    # 6. introspect class
    r = client.call_tool("lisp_introspect", {"what": "class", "name": "CL:HASH-TABLE"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("introspect class", d["ok"] is True and len(d["result"]["slots"]) > 0, str(d))

    # 7. apropos
    r = client.call_tool("lisp_apropos", {"pattern": "hash"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("apropos", d["ok"] is True and len(d["result"]) > 0, str(d))

    # 8. macroexpand
    r = client.call_tool("lisp_macroexpand", {"form": "(when t 1)", "level": 1})
    d = extract_json(r["result"]["content"][0]["text"])
    check("macroexpand", d["ok"] is True and "IF" in d["result"]["expanded"], str(d))
    check("macroexpand changed flag", d["result"]["changed"] is True, str(d))
    check("macroexpand single-line", "\n" not in d["result"]["expanded"], str(d))

    # 9. describe
    r = client.call_tool("lisp_describe", {"name": "CL:LIST"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("describe", d["ok"] is True and len(d["result"]) > 0, str(d))

    # 10. condition + restart round-trip
    r = client.call_tool("lisp_eval", {"form": '(+ 1 "oops")'})
    d = extract_json(r["result"]["content"][0]["text"])
    check("condition raised", d["ok"] == "condition" and "thread" in d, str(d))
    if d["ok"] == "condition":
        thread = d["thread"]
        r2 = client.call_tool("lisp_invoke_restart", {"thread": thread, "index": 0})
        d2 = extract_json(r2["result"]["content"][0]["text"])
        check("restart round-trip", d2["ok"] is True, str(d2))

    # 11. image survives after abort
    r = client.call_tool("lisp_eval", {"form": "(cube 3)"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("image survives abort", d["ok"] is True and d["result"]["values"] == ["27"], str(d))

    # 12. load file
    test_file = os.path.join(os.path.dirname(__file__), "..", "tests", "sample.lisp")
    with open(test_file, "w") as f:
        f.write('(defun double-it (x) (* x 2))\n')
    r = client.call_tool("lisp_load", {"target": "/work/tests/sample.lisp"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("load file", d["ok"] is True and d["result"]["success"] is True, str(d))
    r = client.call_tool("lisp_eval", {"form": "(double-it 21)"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("loaded function works", d["result"]["values"] == ["42"], str(d))

    # 13. reset
    r = client.call_tool("lisp_reset", {})
    d = extract_json(r["result"]["content"][0]["text"])
    check("reset", d["ok"] is True, str(d))
    r = client.call_tool("lisp_eval", {"form": "(double-it 21)"})
    d = extract_json(r["result"]["content"][0]["text"])
    check("reset clears state", d["ok"] == "condition", str(d))

    client.close()

    # Clean up
    os.remove(test_file)

    # Report
    print("\n=== Test Results ===")
    for status, name in checks:
        print(f"  [{status}] {name}")
    print(f"\n{len(checks) - len(failures)}/{len(checks)} passed")
    if failures:
        print("\nFailures:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("\nAll tests passed!")


if __name__ == "__main__":
    os.makedirs(os.path.join(os.path.dirname(__file__), "..", "tests"), exist_ok=True)
    test()
