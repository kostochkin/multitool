# multitool

Persistent SBCL REPL as an MCP server — gives AI agents a live Common Lisp image for symbolic reasoning, introspection, and interactive development.

Based on the ideas in [From Tool Calling to Symbolic Thinking: LLMs in a Persistent Lisp Metaprogramming Loop](https://arxiv.org/html/2506.10021v1).

## What it does

An opencode (or any MCP-compatible) agent gets 9 tools backed by a persistent SBCL image running in a Docker sandbox:

- `lisp_eval` — evaluate Lisp forms; state persists across calls
- `lisp_introspect` — query packages, symbols, CLOS classes
- `lisp_apropos` — search for symbols by pattern
- `lisp_describe` — full describe output for a symbol
- `lisp_macroexpand` — macroexpand-1 or full macroexpand
- `lisp_load` — load a `.lisp`/`.asd` file or ASDF system
- `lisp_run_tests` — run FiveAM tests
- `lisp_invoke_restart` — choose a restart on a paused condition (the SBCL stack stays alive)
- `lisp_reset` — restart the container for a fresh image

The key feature is **condition round-trip**: when `lisp_eval` raises a condition, the SBCL worker thread pauses (stack alive), the agent receives the condition + available restarts, and can invoke a restart by index. This is the Lisp debugger model, adapted for tool-calling agents.

## Architecture

```
opencode agent
  │  MCP (JSON-RPC over stdio)
  ▼
Python bridge (bridge/)        ← thin adapter: MCP tools ↔ miniswank RPC
  │  JSON-line over stdio (miniswank protocol)
  ▼
SBCL --load server.lisp        ← persistent image (Docker, no network)
  with protocol.lisp, image.lisp
```

- **server.lisp** — miniswank: read-loop, eval with `*debugger-hook*` capture, per-eval worker threads, restart round-trip via mailboxes
- **protocol.lisp** — JSON-line framing (yason)
- **image.lisp** — introspection, apropos, macroexpand, describe, load, FiveAM
- **bridge/transport.py** — manages persistent Docker container, JSON-line RPC
- **bridge/__main__.py** — MCP server (official `mcp` SDK), routes tools to miniswank
- **bridge/tools.py** — MCP tool schemas

## Setup

### Prerequisites
- Docker
- Python 3.10+

### Build

```bash
cd multitool
python3 -m venv .venv
.venv/bin/pip install mcp
docker build -t sbcl-multitool .
```

### Run tests

```bash
.venv/bin/python3 tests/smoke_test.py
```

### Use with opencode

The `.opencode/opencode.json` registers the MCP server. Start opencode in the `multitool/` directory:

```bash
cd multitool
opencode
```

The `symbolic-thinking` skill teaches the agent the Lisp development cycle: introspect → macroexpand → write to file → load → handle conditions → fix.

## Miniswank protocol

JSON-line over stdio:

```jsonl
→ {"id":"r1","method":"eval","params":{"form":"(+ 1 2)"}}
← {"id":"r1","ok":true,"result":{"values":["3"],"stdout":"","conditions":[]}}
← {"id":"r1","ok":"condition","condition":{"type":"TYPE-ERROR","message":"..."},"restarts":[{"name":"ABORT","report":"ABORT"}],"thread":"w1"}
→ {"id":"r2","method":"invoke_restart","params":{"thread":"w1","index":0}}
```

Methods: `eval`, `introspect`, `apropos`, `describe`, `macroexpand`, `load`, `run_tests`, `invoke_restart`.

## Sandbox

Docker container with `--network=bridge` (for swank access), memory/CPU limits, work directory mounted at `/work`. SBCL image dumped with Quicklisp systems: alexandria, fiveam, cl-ppcre, split-sequence, bordeaux-threads, yason, closer-mop, trivial-utf-8, trivial-backtrace, swank.

## Developer access (SLIME/Sly)

A swank server runs on port 4005 inside the container alongside the miniswank stdio loop, so a human developer can attach to the **same live image** the agent works with:

```
M-x slime-connect RET localhost RET 4005
```

Port is configurable via `MULTITOOL_SWANK_PORT` (bridge env, defaults to 4005). The image persists — definitions the agent loads are visible to the developer and vice versa. Close with `M-x slime-quit` (do not kill the container while the agent session is live).

## Networking quirk & build fix

The CloudFront distribution in front of `beta.quicklisp.org` **silently stalls** any request whose `Host` header carries the default-port suffix (`Host: beta.quicklisp.org:80` → timeout, verified with curl on all edge IPs; plain `Host: beta.quicklisp.org` → 200). Quicklisp's client always appends `:80`, so `(quicklisp-quickstart:install)` hangs forever on fetching `releases.txt`.

`host-header-fix.lisp` redefines `ql-http:make-request-buffer` to emit a clean Host header. The build order works around two more subtleties:

1. `mkdir -p /root/quicklisp/dists` **before** quickstart — `maybe-initial-setup` then skips the auto-install of the default dist (`:dist-url nil` does NOT skip it: setup.lisp falls back to the default URL).
2. After the client install and the fix load, the dist is installed explicitly via `(ql-dist:install-dist ...)`, then systems are quickloaded and `save-lisp-and-die` bakes everything (fix included) into the runtime core.

Build with:

```bash
./build.sh            # logs to /tmp/sbcl-multitool-build.log
./build.sh --no-cache # ignore layer cache
```

### Manual container run

For interactive development without the agent:

```bash
./run.sh              # detached dev-session; attach via slime-connect
./run.sh --pipe       # type miniswank JSON-lines by hand (Ctrl-D to exit)
./run.sh --stop       # stop and remove the dev container
```

Env overrides: `MULTITOOL_IMAGE`, `MULTITOOL_WORKDIR`, `MULTITOOL_SWANK_PORT` (e.g. `MULTITOOL_SWANK_PORT=4006 ./run.sh` to avoid a port clash with a live agent session).

## Phase 2

- Dump core between sessions (`sb-ext:save-core`)
- Migrate the Python bridge to self-hosted Lisp — the agent rewrites the bridge in the very SBCL it serves, demonstrating the "symbolic metaprogramming loop" from the paper
- Benchmarks for hybrid symbolic-neural reasoning
