---
name: symbolic-thinking
description: Use when developing in Common Lisp with an SBCL REPL image via the multitool MCP tools. Covers the eval→introspect→macroexpand→load→condition/restart→fix cycle. Use ONLY when the user is working with Common Lisp code and the lisp_* MCP tools are available.
---

# Symbolic Thinking for Common Lisp Development

You have access to a persistent SBCL image through the `lisp_*` MCP tools. This is not a throwaway sandbox — the image maintains state across calls, like a SLIME/SLY REPL session. Use it to reason symbolically about Lisp code.

## Core principle: explore before you write

Lisp is reflective. Before writing code, inspect the live image to ground your understanding in reality, not assumptions.

## The development cycle

1. **Introspect** — use `lisp_introspect` (symbol/class/packages) and `lisp_apropos` to understand what exists. Check arglists, documentation, CLOS class structure.
2. **Macroexpand** — use `lisp_macroexpand` to see what macros expand to. This is how you understand control flow in Lisp — `(when ...)`, `(loop ...)`, `(iterate ...)` all expand to forms you can reason about.
3. **Write & evaluate** — two paths:
   - **Quick experiment**: `lisp_eval` with `(defun ...)` / `(defclass ...)` directly. Fast, but state diverges from files.
   - **Real development**: write to file with your edit tool, then `lisp_load` the file. State on disk = source of truth.
4. **Observe results** — `lisp_eval` returns values + stdout + conditions. Read them carefully.
5. **Handle conditions** — when `lisp_eval` returns `ok: "condition"`:
   - The response includes `restarts` (list with name + report) and a `thread` id.
   - The SBCL image is **paused, not dead** — the stack is alive, waiting for your decision.
   - Use `lisp_invoke_restart` with the `thread` id and a 0-based `index` to choose a restart.
   - Common restarts: `ABORT` (cancel), `CONTINUE` (ignore error), `USE-VALUE` (substitute a value, provide `value` param).
   - If you don't call `lisp_invoke_restart` within 60s, the worker auto-aborts.
   - **You can also just fix the code and re-evaluate** — the previous condition's worker is abandoned.
6. **Fix and reload** — fix the file, `lisp_load` again, re-test. The image picks up redefinitions incrementally.

## When to use each tool

- **`lisp_eval`** — the workhorse. Evaluate any form. Define functions, run code, test hypotheses. State persists.
- **`lisp_introspect`** — before using a symbol, check if it exists, its arglist, its type (function/macro/generic). Don't guess — look.
- **`lisp_apropos`** — when searching for functionality. "Is there a hash-merge function?" → `lisp_apropos` with "merge".
- **`lisp_describe`** — deep dive on a symbol. More detail than introspect.
- **`lisp_macroexpand`** — understand macros. Always macroexpand unfamiliar macros before reasoning about them.
- **`lisp_load`** — load a file or ASDF system into the image. Use `/work/...` paths for project files (work directory is mounted).
- **`lisp_run_tests`** — run FiveAM tests. Load the test system first, then run.
- **`lisp_invoke_restart`** — choose a restart on a paused condition.
- **`lisp_reset`** — nuclear option. Restarts the container, losing all state. Use when the image is broken.

## Patterns

### Exploring a new codebase
```
lisp_introspect what=packages  → see what packages exist
lisp_introspect what=symbols name=MY-PACKAGE  → see exported symbols
lisp_introspect what=symbol name=MY-PACKAGE:FOO  → check FOO's arglist and docs
lisp_describe name=MY-PACKAGE:FOO  → full description
```

### Writing a new function
```
(edit file) → write defun to file
lisp_load target=/work/src/utils.lisp  → load into image
lisp_eval form=(my-func 1 2 3)  → test it
→ if condition: lisp_invoke_restart or fix and reload
```

### Debugging a macro
```
lisp_macroexpand form=(my-macro x y) level=1  → see one step
lisp_macroexpand form=(my-macro x y)  → see full expansion
lisp_eval form=(macro-function 'my-macro)  → check if it's actually a macro
```

### TDD cycle
```
(edit file) → write test with FiveAM
lisp_load target=/work/my-system.asd  → load system
lisp_run_tests system=my-system-tests  → run tests
→ if failures: read stdout, fix, reload, re-run
```

### Handling an undefined function
```
lisp_eval form=(undefined-func 42)
→ condition: UNDEFINED-FUNCTION, restarts: [CONTINUE, USE-VALUE, RETURN-VALUE, ABORT]
→ lisp_invoke_restart thread=w1 index=4  → ABORT (index 4)
→ lisp_eval form=(defun undefined-func (x) (* x 2))  → define it
→ lisp_eval form=(undefined-func 42)  → now works
```

## What NOT to do

- Don't `lisp_eval` large blocks of code — write to files and `lisp_load` instead.
- Don't ignore conditions — they contain diagnostic information. Read the type and message.
- Don't call `lisp_reset` casually — it loses all accumulated definitions.
- Don't use `lisp_invoke_restart` with `USE-VALUE` as a band-aid — fix the root cause.

## Persistence

The SBCL image persists across all tool calls within a session. Functions you define, variables you set, packages you create — all survive. This is the key advantage: you build up an environment incrementally, like a live development session.

## Reference: request/response examples for every tool

Real examples. The JSON shown is the tool output (values are strings; `null` = absent in the image).

### lisp_eval — simple evaluation
```
form: (+ 1 2)
→ {"ok": true, "result": {"values": ["3"], "stdout": "", "conditions": []}}
```

### lisp_eval — stdout capture + multiple values + persistence
```
form: (format t "hello~%")
→ {"ok": true, "result": {"values": ["NIL"], "stdout": "hello\n", "conditions": []}}

form: (values 1 2 3)
→ {"ok": true, "result": {"values": ["1", "2", "3"], "stdout": "", "conditions": []}}

form: (defun square (x) (* x x))
→ {"ok": true, "result": {"values": ["SQUARE"], ...}}   ; definition persists

form: (square 7)
→ {"ok": true, "result": {"values": ["49"], ...}}       ; available in later calls
```

### lisp_eval — condition raised (image pauses, restarts offered)
```
form: (+ 1 "oops")
→ {"ok": "condition",
   "condition": {"type": "TYPE-ERROR",
                 "message": "The value\n  \"oops\"\nis not of type\n  NUMBER"},
   "restarts": [{"name": "ABORT", "report": "ABORT"},
                {"name": "ABORT", "report": "ABORT"}],
   "thread": "w1"}
```

### lisp_invoke_restart — pick restart by 0-based index
```
thread: w1, index: 0            → ABORT unwinds the eval
→ {"ok": true, "result": {"values": [], "stdout": "", "conditions": []}}
; after ABORT the image is alive: (defun ...) and later evals still work

thread: w2, index: 1, value: "42"   → USE-VALUE with a Lisp value
→ same shape as a normal result; eval continues with 42 substituted
```

### lisp_eval — undefined function (richer restart set)
```
form: (sq 9)
→ {"ok": "condition",
   "condition": {"type": "UNDEFINED-FUNCTION",
                 "message": "The function COMMON-LISP-USER::SQ is undefined."},
   "restarts": [{"name": "CONTINUE"}, {"name": "USE-VALUE"},
                {"name": "RETURN-VALUE"}, {"name": "RETURN-NOTHING"},
                {"name": "ABORT"}, {"name": "ABORT"}],
   "thread": "w1"}
; typical move: ABORT (last index), then (defun sq ...) and retry
```

### lisp_introspect — packages / symbols / symbol / class
```
what: packages
→ {"ok": true, "result": ["COMMON-LISP", "ALEXANDRIA", ...]}   ; sorted names

what: symbols, name: ALEXANDRIA
→ {"ok": true, "result": ["ALEXANDRIA:WHEN-LET", "..."]}       ; external symbols

what: symbol, name: CL:LIST
→ {"ok": true, "result": {"name": "LIST", "package": "COMMON-LISP",
                          "fboundp": true, "boundp": null,
                          "type": "compiled-function", "macro": null,
                          "arglist": null,
                          "documentation": "Construct and return a list containing the objects ARGS."}}

what: class, name: CL:HASH-TABLE
→ {"ok": true, "result": {"name": "HASH-TABLE", "superclasses": [...],
                          "subclasses": [...], "slots": [{"name": "...", "allocation": "..."}],
                          "documentation": "..."}}
```

### lisp_apropos — symbol search (case-insensitive substring)
```
pattern: hash
→ {"ok": true, "result": [{"name": "MAKE-HASH-TABLE", "package": "COMMON-LISP",
                           "fboundp": true, "boundp": null}, ...]}
; can match hundreds — narrow the pattern or scan package-external symbols via lisp_introspect
```

### lisp_describe — full human-readable description
```
name: CL:LIST
→ {"ok": true, "result": "LIST is a symbol...\nPackage: COMMON-LISP...\n"}  ; multi-line text
```

### lisp_macroexpand — one step (level 1) vs full
```
form: (when t 1), level: 1
→ {"ok": true, "result": {"expanded": "(IF T\n    1)", "changed": true}}
; changed=false means the form was already not a macro call

form: (loop for i below 3 collect i)      ; no level = expand to the bottom
→ {"ok": true, "result": {"expanded": "(SB-LOOP::DO ...)", "changed": true}}
```

### lisp_load — file (mounted at /work) or ASDF system
```
target: /work/src/utils.lisp
→ {"ok": true, "result": {"success": true, "stdout": ""}}
; definitions are immediately usable: (greet "world") → "Hello, world!"

target: alexandria                         ; no extension → ASDF system
→ {"ok": true, "result": {"success": true, "stdout": "..."}}
; on failure: {"success": false, "error": "...", "stdout": "..."}
```

### lisp_run_tests — FiveAM
```
system: my-project-tests                   ; optional: ASDF system loaded first
→ {"ok": true, "result": {"success": true, "stdout": "<FiveAM report>"}}
; failures and failures summary appear in stdout — read it fully
```

### lisp_reset — fresh image
```
(no arguments)
→ {"ok": true, "result": {"message": "image reset"}}
; container recreated: every definition is gone, package state back to default
```
