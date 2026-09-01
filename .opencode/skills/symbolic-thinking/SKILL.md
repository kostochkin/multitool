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

## Reference: complete copy-pasteable request/response examples

Real captured sessions. Every line below is complete, valid JSON.
Paste a request line into `./run.sh --pipe` and it works as-is. As an
MCP tool call, use the same `params` object as the tool arguments
(`id` is arbitrary). The line after `→` is the verbatim response.

### lisp_eval — evaluation, stdout, multiple values, persistence
```json
{"id":"r1","method":"eval","params":{"form":"(+ 1 2)"}}
→ {"id":"r1","ok":true,"result":{"values":["3"],"stdout":"","conditions":[]}}

{"id":"r2","method":"eval","params":{"form":"(format t \"hello~%\")"}}
→ {"id":"r2","ok":true,"result":{"values":["NIL"],"stdout":"hello\n","conditions":[]}}

{"id":"r3","method":"eval","params":{"form":"(values 1 2 3)"}}
→ {"id":"r3","ok":true,"result":{"values":["1","2","3"],"stdout":"","conditions":[]}}

{"id":"r4","method":"eval","params":{"form":"(defun square (x) (* x x))"}}
→ {"id":"r4","ok":true,"result":{"values":["SQUARE"],"stdout":"","conditions":[]}}
; definition persists in the image

{"id":"r5","method":"eval","params":{"form":"(square 7)"}}
→ {"id":"r5","ok":true,"result":{"values":["49"],"stdout":"","conditions":[]}}
; 49 — defined function callable in later requests
```

### lisp_eval — condition raised (image pauses, restarts offered)
```json
{"id":"r6","method":"eval","params":{"form":"(+ 1 \"oops\")"}}
→ {"id":"r6","ok":"condition","condition":{"type":"TYPE-ERROR","message":"The value\n  \"oops\"\nis not of type\n  NUMBER"},"restarts":[{"name":"ABORT","report":"ABORT"},{"name":"ABORT","report":"ABORT"}],"thread":"w6"}
; ok is "condition", not true: the worker thread is PAUSED, stack alive.

{"id":"r8","method":"eval","params":{"form":"(sq 9)"}}
→ {"id":"r8","ok":"condition","condition":{"type":"UNDEFINED-FUNCTION","message":"The function COMMON-LISP-USER::SQ is undefined."},"restarts":[{"name":"CONTINUE","report":"CONTINUE"},{"name":"USE-VALUE","report":"USE-VALUE"},{"name":"RETURN-VALUE","report":"RETURN-VALUE"},{"name":"RETURN-NOTHING","report":"RETURN-NOTHING"},{"name":"ABORT","report":"ABORT"},{"name":"ABORT","report":"ABORT"}],"thread":"w7"}
; undefined function: richer restart set (CONTINUE, USE-VALUE, ...)
```

### lisp_invoke_restart — pick a restart by 0-based index
```json
{"id":"r7","method":"invoke_restart","params":{"thread":"w6","index":0}}
→ {"id":"r7","ok":true,"result":{"values":[],"stdout":"","conditions":[]}}
; index 0 = first ABORT: unwinds the eval, worker returns a result.

{"id":"r9","method":"invoke_restart","params":{"thread":"w7","index":4}}
→ {"id":"r9","ok":true,"result":{"values":[],"stdout":"; in: SQ 9\n;     (SQ 9)\n; \n; caught STYLE-WARNING:\n;   undefined function: COMMON-LISP-USER::SQ\n; \n; compilation unit finished\n;   Undefined function:\n;     SQ\n;   caught 1 STYLE-WARNING condition\n","conditions":[]}}
; index 4 = ABORT on the UNDEFINED-FUNCTION condition.

{"id":"r10","method":"eval","params":{"form":"(defun sq (x) (* x x))"}}
→ {"id":"r10","ok":true,"result":{"values":["SQ"],"stdout":"","conditions":[]}}

{"id":"r11","method":"eval","params":{"form":"(sq 9)"}}
→ {"id":"r11","ok":true,"result":{"values":["81"],"stdout":"","conditions":[]}}
; image survived the abort: define sq and it works. Do this instead of
; guessing restarts when the fix is obvious.
```

### lisp_introspect — all packages
```json
{"id":"r12","method":"introspect","params":{"what":"packages"}}
→ {"id":"r12","ok":true,"result":["ALEXANDRIA","ALEXANDRIA-2","ASDF/ACTION","ASDF/BACKWARD-INTERFACE","ASDF/BACKWARD-INTERNALS","ASDF/BUNDLE","ASDF/COMPONENT","ASDF/CONCATENATE-SOURCE","ASDF/FIND-COMPONENT","ASDF/FIND-SYSTEM","ASDF/FORCING","ASDF/LISP-ACTION","ASDF/OPERATE","ASDF/OPERATION","ASDF/OUTPUT-TRANSLATIONS","ASDF/PACKAGE-INFERRED-SYSTEM","ASDF/PARSE-DEFSYSTEM","ASDF/PLAN","ASDF/SESSION","ASDF/SOURCE-REGISTRY","ASDF/SYSTEM","ASDF/SYSTEM-REGISTRY","ASDF/UPGRADE","ASDF/USER","AUTOLOAD","BORDEAUX-THREADS","BT2","CL-PPCRE","CLOSER-MOP","COMMON-LISP","COMMON-LISP-USER","DREF-EXT","GLOBAL-VARS","IT.BESE.FIVEAM","KEYWORD","MGL-PAX","MGL-PAX.ASDF","MULTITOOL-IMAGE","MULTITOOL-PROTOCOL","MULTITOOL-SERVER","NET.DIDIERVERNA.ASDF-FLV","QL-ABCL","QL-ALLEGRO","QL-BUNDLE","QL-CCL","QL-CDB","QL-CLASP","QL-CLISP","QL-CMUCL","QL-CONFIG","QL-DIST","QL-ECL","QL-GUNZIPPER","QL-HTTP","QL-IMPL","QL-IMPL-UTIL","QL-INFO","QL-LISPWORKS","QL-MEZZANO","QL-MINITAR","QL-MKCL","QL-NETWORK","QL-PROGRESS","QL-SBCL","QL-SCL","QL-SETUP","QL-UTIL","QLQS-ABCL","QLQS-ALLEGRO","QLQS-CCL","QLQS-CLASP","QLQS-CLISP","QLQS-CMUCL","QLQS-ECL","QLQS-HTTP","QLQS-IMPL","QLQS-IMPL-UTIL","QLQS-INFO","QLQS-LISPWORKS","QLQS-MINITAR","QLQS-MKCL","QLQS-NETWORK","QLQS-PROGRESS","QLQS-SBCL","QLQS-SCL","QUICKLISP-CLIENT","QUICKLISP-QUICKSTART","SB-ALIEN","SB-ALIEN-INTERNALS","SB-APROF","SB-ASSEM","SB-BIGNUM","SB-BROTHERTREE","SB-BSD-SOCKETS","SB-BSD-SOCKETS-INTERNAL","SB-C","SB-CLTL2","SB-DEBUG","SB-DI","SB-DISASSEM","SB-EVAL","SB-EXT","SB-FASL","SB-FORMAT","SB-GRAY","SB-IMPL","SB-INT","SB-INTROSPECT","SB-KERNEL","SB-LOCKLESS","SB-LOOP","SB-MOP","SB-PCL","SB-POSIX","SB-PRETTY","SB-PROFILE","SB-REGALLOC","SB-SEQUENCE","SB-SYS","SB-THREAD","SB-UNICODE","SB-UNIX","SB-VM","SB-WALKER","SB-X86-64-ASM","SPLIT-SEQUENCE","SWANK","SWANK-LOADER","SWANK-MOP","SWANK/BACKEND","SWANK/GRAY","SWANK/MATCH","SWANK/RPC","SWANK/SBCL","SWANK/SOURCE-FILE-CACHE","SWANK/SOURCE-PATH-PARSER","TRIVIAL-BACKTRACE","TRIVIAL-BACKTRACE-SYSTEM","TRIVIAL-GARBAGE","TRIVIAL-GRAY-STREAMS","TRIVIAL-UTF-8","UIOP/BACKWARD-DRIVER","UIOP/COMMON-LISP","UIOP/CONFIGURATION","UIOP/FILESYSTEM","UIOP/IMAGE","UIOP/LAUNCH-PROGRAM","UIOP/LISP-BUILD","UIOP/OS","UIOP/PACKAGE","UIOP/PATHNAME","UIOP/RUN-PROGRAM","UIOP/STREAM","UIOP/UTILITY","UIOP/VERSION","YASON"]}
```

### lisp_introspect — external symbols of a package
```json
{"id":"r13","method":"introspect","params":{"what":"symbols","name":"MULTITOOL-PROTOCOL"}}
→ {"id":"r13","ok":true,"result":["MULTITOOL-PROTOCOL:DECODE-JSON","MULTITOOL-PROTOCOL:ENCODE-JSON","MULTITOOL-PROTOCOL:READ-LINE-JSON","MULTITOOL-PROTOCOL:WRITE-LINE-JSON"]}
; big packages (ALEXANDRIA, CL) return long arrays — same shape
```

### lisp_introspect — one symbol
```json
{"id":"r14","method":"introspect","params":{"what":"symbol","name":"CL:LIST"}}
→ {"id":"r14","ok":true,"result":{"name":"LIST","package":"COMMON-LISP","boundp":null,"fboundp":true,"constantp":null,"specialp":null,"arglist":null,"type":"compiled-function","macro":null,"documentation":"Construct and return a list containing the objects ARGS."}}
```

### lisp_introspect — CLOS class
```json
{"id":"r15","method":"introspect","params":{"what":"class","name":"CL:HASH-TABLE"}}
→ {"id":"r15","ok":true,"result":{"name":"HASH-TABLE","superclasses":["STRUCTURE-OBJECT"],"subclasses":["SB-IMPL::GENERAL-HASH-TABLE"],"slots":[{"name":"SB-IMPL::GETHASH-IMPL","allocation":"INSTANCE"},{"name":"SB-IMPL::PUTHASH-IMPL","allocation":"INSTANCE"},{"name":"SB-IMPL::REMHASH-IMPL","allocation":"INSTANCE"},{"name":"SB-IMPL::%HASH-FUN-STATE","allocation":"INSTANCE"},{"name":"SB-IMPL::PAIRS","allocation":"INSTANCE"},{"name":"SB-IMPL::CACHE","allocation":"INSTANCE"},{"name":"SB-IMPL::INDEX-VECTOR","allocation":"INSTANCE"},{"name":"SB-IMPL::NEXT-VECTOR","allocation":"INSTANCE"},{"name":"SB-IMPL::HASH-VECTOR","allocation":"INSTANCE"},{"name":"SB-IMPL::FLAGS","allocation":"INSTANCE"},{"name":"SB-IMPL::%LOCK","allocation":"INSTANCE"},{"name":"SB-IMPL::TEST-FUN","allocation":"INSTANCE"},{"name":"SB-IMPL::HASH-FUN","allocation":"INSTANCE"},{"name":"SB-IMPL::TEST","allocation":"INSTANCE"},{"name":"SB-IMPL::REHASH-SIZE","allocation":"INSTANCE"},{"name":"SB-IMPL::REHASH-THRESHOLD","allocation":"INSTANCE"},{"name":"SB-IMPL::%COUNT","allocation":"INSTANCE"},{"name":"SB-IMPL::NEXT-FREE-KV","allocation":"INSTANCE"}],"documentation":null}}
```

### lisp_apropos — case-insensitive substring
```json
{"id":"r16","method":"apropos","params":{"pattern":"plist-hash"}}
→ {"id":"r16","ok":true,"result":[{"name":"ALEXANDRIA:PLIST-HASH-TABLE","package":"ALEXANDRIA","boundp":null,"fboundp":true}]}
```

### lisp_describe — full description
```json
{"id":"r17","method":"describe","params":{"name":"CL:LIST"}}
→ {"id":"r17","ok":true,"result":"COMMON-LISP:LIST\n  [symbol]\n\nLIST names a compiled function:\n  Lambda-list: (&REST ARGS)\n  Declared type: (FUNCTION * (VALUES LIST &OPTIONAL))\n  Derived type: (FUNCTION (&REST T) (VALUES LIST &OPTIONAL))\n  Documentation:\n    Construct and return a list containing the objects ARGS.\n  Known attributes: flushable, unsafely-flushable, movable, foldable-read-only\n  Source file: SYS:SRC;CODE;LIST.LISP\n\nLIST names the built-in-class #<BUILT-IN-CLASS COMMON-LISP:LIST>:\n  Class precedence-list: LIST, SEQUENCE, T\n  Direct superclasses: SEQUENCE\n  Direct subclasses: CONS, NULL\n  Sealed.\n  No direct slots.\n"}
```

### lisp_macroexpand — one step (level 1) vs full
```json
{"id":"r18","method":"macroexpand","params":{"form":"(when t 1)","level":1}}
→ {"id":"r18","ok":true,"result":{"expanded":"(IF T 1)","changed":true}}

{"id":"r19","method":"macroexpand","params":{"form":"(when x a b)"}}
→ {"id":"r19","ok":true,"result":{"expanded":"(IF X (PROGN A B))","changed":true}}
; no "level" → expand to the bottom; changed=false → not a macro call
; expansions are always single-line (no pretty-print whitespace)
```

### lisp_load — file mounted at /work
```json
{"id":"r20","method":"load","params":{"target":"/work/examples/sample.lisp"}}
→ {"id":"r20","ok":true,"result":{"success":true,"stdout":""}}
; file lives in the repo at examples/sample.lisp (mounted as /work)
```

### lisp_eval — using loaded definitions
```json
{"id":"r21","method":"eval","params":{"form":"(greet \"world\")"}}
→ {"id":"r21","ok":true,"result":{"values":["\"Hello, world!\""],"stdout":"","conditions":[]}}
```

### lisp_run_tests — FiveAM
```json
{"id":"r22","method":"run_tests","params":{}}
→ {"id":"r22","ok":true,"result":{"success":true,"stdout":"\nRunning test suite NIL\n Running test GREET-TEST .\n Did 1 check.\n    Pass: 1 (100%)\n    Skip: 0 ( 0%)\n    Fail: 0 ( 0%)\n"}}
; runs tests defined in CL-USER; load your test system first for real suites
```

### lisp_reset — MCP tool only (no wire method)
```json
{}
→ {"ok": true, "result": {"message": "image reset"}}
; the bridge recreates the container: ALL state is gone
```
