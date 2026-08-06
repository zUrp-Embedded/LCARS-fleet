#!/usr/bin/env python3
# SOURCE: test/fixtures/mcp_submit_server.py
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# mcp_submit_server.py — TEST FIXTURE (not runtime code). Minimal stdio MCP server, zero deps, a
# stand-in for the real `fleet_mcp`. BIDIRECTIONAL pod comm over MCP (never scraping):
#   - submit_result: OUT channel — the pod returns a structured result (→ $LCARS_SUBMIT_PATH).
#   - get_task     : IN channel  — the pod PULLs its next task from the fleet queue ($LCARS_TASK_QUEUE,
#                    a JSON list); pops the first; {"done": true} when empty. Multi-turn fleet→pod with
#                    no keyboard injection and no scraping.
#
# STATUS OF THIS FILE, stated because its location does not say it: it has NO live consumer. Its only
# referrer is test/_archived_gates/gate-r-core-comm-inc4.sh, which short-circuits (it is a RETIRED
# gate). It is kept as the data an archived gate would need if that gate were ever revived — which is
# also why its tool is still named `get_task`: renaming it to the current `get_work_item` would break
# the only thing that could ever drive it. Do not read this file as an example of the live protocol;
# lib/fleet/mcp/pod_tools.ex is.
import json, os, sys

SUBMIT_PATH = os.environ.get("LCARS_SUBMIT_PATH", "/tmp/lcars-submit.json")
TASK_QUEUE = os.environ.get("LCARS_TASK_QUEUE", "")
PROTO = "2024-11-05"

def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

def next_task():
    # Pop the first task off the queue (read-modify-write). {"done": true} if empty or missing.
    if not TASK_QUEUE or not os.path.exists(TASK_QUEUE):
        return {"done": True}
    try:
        tasks = json.load(open(TASK_QUEUE))
    except Exception:
        return {"done": True}
    if not tasks:
        return {"done": True}
    task = tasks.pop(0)
    with open(TASK_QUEUE, "w") as f:
        json.dump(tasks, f, ensure_ascii=False)
    return {"done": False, "task": task}

TOOLS = [
    {
        "name": "get_task",
        "description": "Fetch your next task from the LCARS fleet. Returns {\"done\":true} when there is "
                       "no task left (you then stop), otherwise {\"done\":false,\"task\":{...}}.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "submit_result",
        "description": "Return a task's structured result to the LCARS fleet, in `payload`.",
        "inputSchema": {
            "type": "object",
            "properties": {"payload": {"type": "object", "description": "Structured result (free-form object)."}},
            "required": ["payload"],
        },
    },
]

def main():
    print(f"[mcp_submit_server] start SUBMIT_PATH={SUBMIT_PATH}", file=sys.stderr, flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": PROTO, "capabilities": {"tools": {}},
                "serverInfo": {"name": "fleet-submit", "version": "0.1.0"}}})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            p = msg.get("params", {})
            name = p.get("name")
            if name == "get_task":
                t = next_task()
                print(f"[mcp_submit_server] get_task -> {t}", file=sys.stderr, flush=True)
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": json.dumps(t, ensure_ascii=False)}]}})
            elif name == "submit_result":
                payload = p.get("arguments", {}).get("payload", {})
                with open(SUBMIT_PATH, "w") as f:
                    json.dump(payload, f, ensure_ascii=False)
                print(f"[mcp_submit_server] submit_result -> {SUBMIT_PATH}: {payload}", file=sys.stderr, flush=True)
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "Result received by the fleet. Task closed."}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown tool"}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})

if __name__ == "__main__":
    main()
