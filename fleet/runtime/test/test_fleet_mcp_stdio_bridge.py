#!/usr/bin/env python3
# SOURCE: fleet/runtime/test/test_fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation run 2026-05-27)
# STARDATE: 2026.147
# STATUS: test regression — pont MCP stdio (bin/fleet_mcp_stdio_bridge.py), central STUBBE (socket AF_UNIX).
#
# Couvre (test du SHIM, central stubbe sur une socket AF_UNIX locale) : handshake stdio MCP
# (initialize/tools/list), tools/call forwarde au central via la socket per-pod, NON-injection
# d'identite (les arguments sont forwardes TELS QUELS — aucune cle `_lcars_*`, meme si LCARS_POD_ID
# est dans l'env), erreur JSON-RPC -32601 sur methode inconnue, erreur JSON-RPC -32000 quand la socket
# est injoignable (pas de crash silencieux), et (MA-19) le schema create_ticket en mode architecte
# (exige `project`, sync avec le central).
# NE couvre PAS (= e2e gates supervises) : le vrai central fleet_mcp (round-trip Elixir),
# l'execution dans un vrai pod bwrap.
# Run : python3 fleet/runtime/test/test_fleet_mcp_stdio_bridge.py  (exit 0 = pass).
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading

BRIDGE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "bin", "fleet_mcp_stdio_bridge.py",
)
received = []

# Stub du central sur une socket AF_UNIX locale (a la place de Fleet.MCP.PodSocketAcceptor). Le pont
# fait connect→une ligne→une ligne→close PAR appel : chaque connexion = un handler. Newline-framed
# (comme `{:packet, :line}` cote Elixir) : on lit UNE ligne (readline → jusqu'au `\n`), on repond UNE
# ligne (`json + "\n"`). La reponse est l'enveloppe JSON-RPC complete avec `result` (le pont en extrait
# le champ `result`). `_echo_args` renvoie les arguments forwardes → on prouve qu'AUCUNE identite n'y
# a ete injectee.


class Stub(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline()
        if not line:
            return
        body = json.loads(line.decode())
        received.append(body)
        resp = {"jsonrpc": "2.0", "id": body.get("id"),
                "result": {"done": False, "task": {"id": "T1"},
                           "_echo_args": body.get("params", {}).get("arguments")}}
        self.wfile.write((json.dumps(resp) + "\n").encode())
        self.wfile.flush()


# Le chemin AF_UNIX est borne a ~108 octets — un dir tmp court suffit largement.
SOCK_DIR = tempfile.mkdtemp(prefix="lcars-mcp-bridge-")
SOCK_PATH = os.path.join(SOCK_DIR, "central.sock")
srv = socketserver.ThreadingUnixStreamServer(SOCK_PATH, Stub)
srv.daemon_threads = True
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


print("--- Test A : handshake + tools + forward via socket (mode tools-only) ---")
# LCARS_POD_ID est POSE dans l'env mais le pont ne le lit plus : il NE DOIT PAS apparaitre dans les
# args forwardes (l'identite vient du canal cote central, plus jamais du wire).
base = {"LCARS_FLEET_MCP_SOCKET": SOCK_PATH, "LCARS_POD_ID": "test-pod-42"}
by_id = run_bridge(base, [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "get_task", "arguments": {"foo": "bar"}}},
])
init = by_id.get(1, {}).get("result", {})
check(init.get("protocolVersion") == "2024-11-05", "initialize -> protocolVersion 2024-11-05")
check("tools" in init.get("capabilities", {}), "initialize -> capabilities.tools")
check("experimental" not in init.get("capabilities", {}), "initialize -> pas de capability experimental")
tools = sorted(t["name"] for t in by_id.get(2, {}).get("result", {}).get("tools", []))
check(tools == ["get_task", "submit_result"], f"tools/list -> {tools}")
check(by_id.get(3, {}).get("result", {}).get("task", {}).get("id") == "T1", "tools/call -> result central renvoye")
check(received and received[-1].get("method") == "tools/call", "central a recu method=tools/call")
# NON-injection d'identite : les arguments arrivent au central EXACTEMENT comme envoyes par claude,
# sans aucune cle `_lcars_*` ajoutee (meme avec LCARS_POD_ID dans l'env). C'est le coeur du fix R9.
fwd_args = received[-1].get("params", {}).get("arguments", {}) if received else {}
lcars_keys = sorted(k for k in fwd_args if k.startswith("_lcars_"))
check(lcars_keys == [], f"AUCUNE identite _lcars_* injectee (args forwardes: {sorted(fwd_args)})")
check(fwd_args == {"foo": "bar"}, f"arguments forwardes TELS QUELS ({fwd_args})")

print("--- Test B : socket injoignable -> erreur JSON-RPC -32000 (pas de crash silencieux) ---")
nogo = {"LCARS_FLEET_MCP_SOCKET": os.path.join(SOCK_DIR, "absente.sock")}
by_idB = run_bridge(nogo, [
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "get_task", "arguments": {}}},
])
errB = by_idB.get(7, {}).get("error", {})
check(errB.get("code") == -32000, f"socket absente -> error -32000 ({errB.get('code')})")

print("--- Test C : methode inconnue -> JSON-RPC error -32601 ---")
by_id3 = run_bridge(base, [{"jsonrpc": "2.0", "id": 9, "method": "bogus/method", "params": {}}])
check(by_id3.get(9, {}).get("error", {}).get("code") == -32601, "methode inconnue -> error -32601")

print("--- Test D (MA-19) : create_ticket exige `project` en mode architecte ---")
# Le central (apps/fleet_mcp/.../pod_tools.ex) REFUSE create_ticket sans `project` (F-TICKET-ROUTE-FOOTGUN).
# Le bridge DOIT exposer le meme schema, sinon l'arch lit un schema stale, omet `project`, et le central
# refuse. On verifie que `project` est present dans properties ET required du tool create_ticket (mode arch).
arch = dict(base, LCARS_ROLE="architect")
by_id4 = run_bridge(arch, [{"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {}}])
arch_tools = {t["name"]: t for t in by_id4.get(4, {}).get("result", {}).get("tools", [])}
check("create_ticket" in arch_tools, f"mode architecte expose create_ticket ({sorted(arch_tools)})")
ct_schema = arch_tools.get("create_ticket", {}).get("inputSchema", {})
ct_required = ct_schema.get("required", [])
ct_props = ct_schema.get("properties", {})
check("project" in ct_props, f"create_ticket.properties contient `project` ({sorted(ct_props)})")
check("project" in ct_required, f"create_ticket.required contient `project` ({ct_required})")
# Anti-regression : un pod NON-architecte ne voit PAS create_ticket (deny-par-defaut par role).
by_id5 = run_bridge(base, [{"jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": {}}])
worker_tools = {t["name"] for t in by_id5.get(5, {}).get("result", {}).get("tools", [])}
check("create_ticket" not in worker_tools, f"role non-arch ne voit PAS create_ticket ({sorted(worker_tools)})")

srv.shutdown()
try:
    os.remove(SOCK_PATH)
except OSError:
    pass
os.rmdir(SOCK_DIR)

print("\n=== VERDICT:", "ALL PASS" if ok else "FAILURES", "===")
sys.exit(0 if ok else 1)
