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
