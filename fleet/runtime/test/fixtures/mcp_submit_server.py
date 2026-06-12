#!/usr/bin/env python3
# SOURCE: test/fixtures/mcp_submit_server.py
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# mcp_submit_server.py — FIXTURE DE TEST (pas du code runtime). Serveur MCP stdio minimal, zéro dep,
# stand-in du futur `fleet_mcp` http_sse. Substrat de comm pod BIDIRECTIONNEL via MCP (jamais scraping) :
#   - submit_result : canal OUT — le pod retourne un résultat structuré (→ $LCARS_SUBMIT_PATH).
#   - get_task      : canal IN  — le pod PULL sa prochaine tâche depuis la file fleet ($LCARS_TASK_QUEUE,
#                     liste JSON) ; pop la 1ère ; {"done": true} quand vide. Multi-turn fleet→pod sans
#                     injection-clavier ni scraping. Mécanisme prouvé keystone 2026-05-24.
import json, os, sys

SUBMIT_PATH = os.environ.get("LCARS_SUBMIT_PATH", "/tmp/lcars-submit.json")
TASK_QUEUE = os.environ.get("LCARS_TASK_QUEUE", "")
PROTO = "2024-11-05"

def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

def next_task():
    # Pop la 1ère tâche de la file (read-modify-write). {"done": true} si vide/absente.
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
        "description": "Recupere ta prochaine tache aupres du fleet LCARS. Retourne {\"done\":true} quand "
                       "il n'y a plus de tache (tu t'arretes alors), sinon {\"done\":false,\"task\":{...}}.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "submit_result",
        "description": "Retourne le resultat structure d'une tache au fleet LCARS, dans `payload`.",
        "inputSchema": {
            "type": "object",
            "properties": {"payload": {"type": "object", "description": "Resultat structure (objet libre)."}},
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
                    "content": [{"type": "text", "text": "Resultat recu par le fleet. Tache close."}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown tool"}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})

if __name__ == "__main__":
    main()
