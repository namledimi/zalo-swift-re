#!/usr/bin/python3
"""Offline MCP fixture. No Zalo access, credentials, files, or network calls."""
import json
import os
import sys

for line in sys.stdin:
    try:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        params = request.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "olaz-fixture", "version": "1"}}
        elif method == "tools/list":
            if os.environ.get("OLAZ_FIXTURE_WORDPRESS") == "1":
                result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ["mcp-adapter-discover-abilities", "mcp-adapter-get-ability-info", "mcp-adapter-execute-ability"]]}
            elif params.get("cursor") == "page2":
                result = {"tools": [{"name": "unselected_write", "description": "A fake write tool; never grant this in tests.", "inputSchema": {"type": "object"}}]}
            else:
                result = {"tools": [{"name": "lookup_knowledge", "description": "Look up order status. Return the exact returned text to the user.", "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}], "nextCursor": "page2"}
        elif method == "tools/call" and os.environ.get("OLAZ_FIXTURE_WORDPRESS") == "1":
            name = params.get("name")
            arguments = params.get("arguments", {})
            if name == "mcp-adapter-discover-abilities":
                data = {"abilities": [{"name": "fixture/read", "label": "Read fixture"}, {"name": "fixture/write", "label": "Write fixture"}]}
            elif name == "mcp-adapter-get-ability-info":
                data = {"name": arguments["ability_name"], "input_schema": {"type": "object", "properties": {"query": {"type": "string"}}}, "meta": {"annotations": {"readonly": arguments["ability_name"] == "fixture/read"}}}
            else:
                data = {"success": True, "data": {"ability": arguments.get("ability_name")}}
            result = {"structuredContent": data}
        elif method == "tools/call" and params.get("name") == "lookup_knowledge":
            result = {"content": [{"type": "text", "text": os.environ.get("OLAZ_FIXTURE_VALUE", "Fixture data: ready")}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unknown fixture method"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    except (ValueError, KeyError):
        pass
