import asyncio
import json
import os

from mcp.server import NotificationOptions
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp import types

from .tools import TOOLS
from .transport import DockerTransport

transport: DockerTransport | None = None


def get_transport() -> DockerTransport:
    global transport
    if transport is None:
        workdir = os.environ.get("MULTITOOL_WORKDIR") or os.getcwd()
        image = os.environ.get("MULTITOOL_IMAGE", "sbcl-multitool:latest")
        swank_port = int(os.environ.get("MULTITOOL_SWANK_PORT", "4005"))
        transport = DockerTransport(image=image, workdir=workdir, swank_port=swank_port)
        transport.start()
    return transport


async def handle_list_tools(ctx, params: types.PaginatedRequestParams) -> types.ListToolsResult:
    return types.ListToolsResult(tools=TOOLS)


async def handle_call_tool(ctx, params: types.CallToolRequestParams) -> types.CallToolResult:
    t = get_transport()
    name = params.name
    arguments = params.arguments or {}

    if name == "lisp_eval":
        resp = t.call("eval", {"form": arguments["form"]})
    elif name == "lisp_introspect":
        p = {"what": arguments["what"]}
        if "name" in arguments:
            p["name"] = arguments["name"]
        resp = t.call("introspect", p)
    elif name == "lisp_apropos":
        resp = t.call("apropos", {"pattern": arguments["pattern"]})
    elif name == "lisp_describe":
        resp = t.call("describe", {"name": arguments["name"]})
    elif name == "lisp_macroexpand":
        p = {"form": arguments["form"]}
        if "level" in arguments:
            p["level"] = arguments["level"]
        resp = t.call("macroexpand", p)
    elif name == "lisp_load":
        resp = t.call("load", {"target": arguments["target"]})
    elif name == "lisp_run_tests":
        p = {}
        if "system" in arguments:
            p["system"] = arguments["system"]
        resp = t.call("run_tests", p)
    elif name == "lisp_invoke_restart":
        p = {"thread": arguments["thread"], "index": arguments["index"]}
        if "value" in arguments:
            p["value"] = arguments["value"]
        resp = t.call("invoke_restart", p)
    elif name == "lisp_reset":
        t.reset()
        resp = {"ok": True, "result": {"message": "image reset"}}
    else:
        return types.CallToolResult(
            content=[types.TextContent(type="text", text=f"Unknown tool: {name}")],
            isError=True,
        )

    return types.CallToolResult(
        content=[types.TextContent(type="text", text=json.dumps(resp, indent=2))]
    )


def main() -> None:
    server = Server(
        "multitool-sbcl",
        on_list_tools=handle_list_tools,
        on_call_tool=handle_call_tool,
    )

    async def _run() -> None:
        async with stdio_server() as (read, write):
            await server.run(
                read, write, server.create_initialization_options()
            )

    asyncio.run(_run())


if __name__ == "__main__":
    main()
