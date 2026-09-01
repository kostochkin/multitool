import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from transport import DockerTransport

t = DockerTransport(image="sbcl-multitool:latest", workdir=os.getcwd())
t.start()

print("=== eval (+ 1 2) ===")
r = t.call("eval", {"form": "(+ 1 2)"})
print(json.dumps(r))

print("=== eval defun + call ===")
r1 = t.call("eval", {"form": "(defun sq (x) (* x x))"})
r2 = t.call("eval", {"form": "(sq 9)"})
print(json.dumps(r1))
print(json.dumps(r2))

print("=== condition + restart ===")
r3 = t.call("eval", {"form": '(+ 1 "oops")'})
print(json.dumps(r3))
if r3.get("ok") == "condition":
    thread = r3["thread"]
    r4 = t.call("invoke_restart", {"thread": thread, "index": 0})
    print(json.dumps(r4))

print("=== introspect symbol ===")
r5 = t.call("introspect", {"what": "symbol", "name": "CL:LIST"})
print(json.dumps(r5))

print("=== macroexpand ===")
r6 = t.call("macroexpand", {"form": "(when t 1)", "level": 1})
print(json.dumps(r6))

print("=== reset ===")
t.reset()
r7 = t.call("eval", {"form": "(sq 9)"})
print("after reset, sq should be undefined:")
print(json.dumps(r7))

t.stop()
print("=== done ===")
