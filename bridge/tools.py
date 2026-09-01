from mcp.types import Tool


TOOLS: list[Tool] = [
    Tool(
        name="lisp_eval",
        description="Evaluate a Common Lisp form in the persistent SBCL image. State persists across calls. Returns values, captured stdout, and any conditions. If a condition is raised, returns restarts and a thread id — use lisp_invoke_restart to choose one.",
        inputSchema={
            "type": "object",
            "properties": {
                "form": {
                    "type": "string",
                    "description": "A Common Lisp expression, e.g. (+ 1 2), (defun foo (x) (* x x)), (mapcar #'car '((1 a) (2 b)))",
                }
            },
            "required": ["form"],
        },
    ),
    Tool(
        name="lisp_introspect",
        description="Introspect the live SBCL image. Query packages, symbols, or CLOS classes. For symbols returns: boundp, fboundp, arglist, type, documentation, value. For classes returns: superclasses, subclasses, slots.",
        inputSchema={
            "type": "object",
            "properties": {
                "what": {
                    "type": "string",
                    "enum": ["packages", "symbols", "symbol", "class"],
                    "description": "What to introspect: 'packages' (all package names), 'symbols' (external symbols of a package), 'symbol' (details of one symbol), 'class' (CLOS class details)",
                },
                "name": {
                    "type": "string",
                    "description": "Symbol/package/class name, e.g. 'CL:LIST', 'ALEXANDRIA', 'CL:HASH-TABLE'. Required for 'symbols', 'symbol', 'class'.",
                },
            },
            "required": ["what"],
        },
    ),
    Tool(
        name="lisp_apropos",
        description="Search for symbols matching a pattern (case-insensitive substring). Returns name, package, boundp, fboundp for each match.",
        inputSchema={
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Substring to search for, e.g. 'hash', 'reduce', 'map'",
                }
            },
            "required": ["pattern"],
        },
    ),
    Tool(
        name="lisp_describe",
        description="Describe a symbol — full human-readable description including type, documentation, methods, etc.",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Symbol name, e.g. 'CL:LIST', 'ALEXANDRIA:PLIST-HASH-TABLE'",
                }
            },
            "required": ["name"],
        },
    ),
    Tool(
        name="lisp_macroexpand",
        description="Macroexpand a Lisp form. Returns the expanded form and whether it changed.",
        inputSchema={
            "type": "object",
            "properties": {
                "form": {
                    "type": "string",
                    "description": "A Lisp macro form, e.g. '(when t 1)', '(loop for i below 3 collect i)'",
                },
                "level": {
                    "type": "integer",
                    "description": "1 for single-step macroexpand-1, omit/0 for full macroexpand",
                },
            },
            "required": ["form"],
        },
    ),
    Tool(
        name="lisp_load",
        description="Load a Lisp file (.lisp, .asd) or ASDF system into the live image. The file is loaded incrementally — definitions become available immediately. Mount the work directory to load project files via /work/... paths.",
        inputSchema={
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "File path (e.g. /work/src/utils.lisp, /work/my-system.asd) or ASDF system name (e.g. 'alexandria')",
                }
            },
            "required": ["target"],
        },
    ),
    Tool(
        name="lisp_run_tests",
        description="Run FiveAM tests. Optionally loads an ASDF system first, then runs all FiveAM tests in the image. Returns stdout with test results.",
        inputSchema={
            "type": "object",
            "properties": {
                "system": {
                    "type": "string",
                    "description": "ASDF system name to load before running tests, e.g. 'my-project-tests'",
                }
            },
        },
    ),
    Tool(
        name="lisp_invoke_restart",
        description="Invoke a restart on a paused condition. After lisp_eval raises a condition, the response includes restarts (by index) and a thread id. Use this tool to choose a restart by its 0-based index. For USE-VALUE/STORE-VALUE restarts, provide a 'value' string. If you don't call this, the worker auto-aborts after 60s.",
        inputSchema={
            "type": "object",
            "properties": {
                "thread": {
                    "type": "string",
                    "description": "Thread id from the condition response, e.g. 'w1'",
                },
                "index": {
                    "type": "integer",
                    "description": "0-based index into the restarts list from the condition response",
                },
                "value": {
                    "type": "string",
                    "description": "Value for USE-VALUE/STORE-VALUE restarts (read as a Lisp expression), e.g. '42' or '\"hello\"'",
                },
            },
            "required": ["thread", "index"],
        },
    ),
    Tool(
        name="lisp_reset",
        description="Reset the SBCL image to a clean state by restarting the container. All definitions and state are lost. Use when the image is in a broken state or you want a fresh start.",
        inputSchema={"type": "object", "properties": {}},
    ),
]
