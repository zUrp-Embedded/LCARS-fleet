#!/usr/bin/env python3
# SOURCE: fleet/runtime/test/test_fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation run 2026-05-27)
# STARDATE: 2026.147
# STATUS: test regression — pont MCP stdio (bin/fleet_mcp_stdio_bridge.py), central STUBBE.
#
# Couvre (test du SHIM, central stubbe en HTTP) : handshake stdio MCP (initialize/tools/list),
# tools/call forwarde au central + injection _lcars_pod_id, declaration capability claude/channel
# si CHANNEL_URL set, erreur JSON-RPC -32601 sur methode inconnue.
# NE couvre PAS (= e2e gates supervises) : la poll-loop channel reelle, le vrai central fleet_mcp,
# l'execution dans un vrai pod bwrap.
# Run : python3 fleet/runtime/test/test_fleet_mcp_stdio_bridge.py  (exit 0 = pass).
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

BRIDGE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "bin", "fleet_mcp_stdio_bridge.py",
)
received = []


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n).decode())
        received.append(body)
        resp = {"jsonrpc": "2.0", "id": body.get("id"),
                "result": {"done": False, "task": {"id": "T1"},
                           "_echo_args": body.get("params", {}).get("arguments")}}
        out = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


srv = HTTPServer(("127.0.0.1", 0), Stub)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

ok = True


def check(cond, label):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + label)
    ok = ok and bool(cond)


def run_bridge(env_extra, reqs):
    env = dict(os.environ)
    env.update(env_extra)
    p = subprocess.Popen(["python3", BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env, text=True)
    inp = "".join(json.dumps(r) + "\n" for r in reqs)
    out, _err = p.communicate(inp, timeout=20)
    resps = [json.loads(l) for l in out.splitlines() if l.strip().startswith("{")]
    return {r.get("id"): r for r in resps if "id" in r}


print("--- Test A : handshake + tools + forward (mode tools-only) ---")
base = {"LCARS_FLEET_MCP_URL": f"http://127.0.0.1:{PORT}/mcp", "LCARS_POD_ID": "test-pod-42"}
by_id = run_bridge(base, [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_task", "arguments": {}}},
])
init = by_id.get(1, {}).get("result", {})
check(init.get("protocolVersion") == "2024-11-05", "initialize -> protocolVersion 2024-11-05")
check("tools" in init.get("capabilities", {}), "initialize -> capabilities.tools")
check("experimental" not in init.get("capabilities", {}), "pas de channel cap si CHANNEL_URL absent")
tools = sorted(t["name"] for t in by_id.get(2, {}).get("result", {}).get("tools", []))
check(tools == ["get_task", "submit_result"], f"tools/list -> {tools}")
check(by_id.get(3, {}).get("result", {}).get("task", {}).get("id") == "T1", "tools/call -> result central renvoye")
check(received and received[-1].get("method") == "tools/call", "central a recu method=tools/call")
inj = received[-1].get("params", {}).get("arguments", {}).get("_lcars_pod_id") if received else None
check(inj == "test-pod-42", f"tools/call -> _lcars_pod_id injecte ({inj})")

print("--- Test B : capability channel declaree si CHANNEL_URL set ---")
ch = dict(base, LCARS_FLEET_MCP_CHANNEL_URL=f"http://127.0.0.1:{PORT}")
by_id2 = run_bridge(ch, [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
caps2 = by_id2.get(1, {}).get("result", {}).get("capabilities", {})
check("claude/channel" in caps2.get("experimental", {}), f"initialize -> experimental.claude/channel ({caps2.get('experimental')})")

print("--- Test C : methode inconnue -> JSON-RPC error -32601 ---")
by_id3 = run_bridge(base, [{"jsonrpc": "2.0", "id": 9, "method": "bogus/method", "params": {}}])
check(by_id3.get(9, {}).get("error", {}).get("code") == -32601, "methode inconnue -> error -32601")

print("\n=== VERDICT:", "ALL PASS" if ok else "FAILURES", "===")
sys.exit(0 if ok else 1)
