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
# est injoignable (pas de crash silencieux), et (MA-19) le schema create_issue en mode architecte
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
        # F-C138 — le central est desormais la source de tools/list (filtre par role, cote serveur). Le
        # pont le FORWARDE (comme tools/call) : on stubbe une reponse tools/list distincte pour prouver le
        # relai. tools/call renvoie l'echo (non-injection d'identite, coeur R9).
        if body.get("method") == "tools/list":
            result = {"tools": [
                {"name": "get_work_item", "inputSchema": {"type": "object", "properties": {}}},
                {"name": "submit_result", "inputSchema": {"type": "object", "properties": {}}},
            ]}
        else:
            result = {"done": False, "task": {"id": "T1"},
                      "_echo_args": body.get("params", {}).get("arguments")}
        resp = {"jsonrpc": "2.0", "id": body.get("id"), "result": result}
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
     "params": {"name": "get_work_item", "arguments": {"foo": "bar"}}},
])
init = by_id.get(1, {}).get("result", {})
check(init.get("protocolVersion") == "2024-11-05", "initialize -> protocolVersion 2024-11-05")
check("tools" in init.get("capabilities", {}), "initialize -> capabilities.tools")
check("experimental" not in init.get("capabilities", {}), "initialize -> pas de capability experimental")
tools = sorted(t["name"] for t in by_id.get(2, {}).get("result", {}).get("tools", []))
# F-C138 — tools/list est FORWARDE au central (plus de catalogue local) : le pont relaie la liste du
# central telle quelle, et le central a bien RECU la methode tools/list.
check(tools == ["get_work_item", "submit_result"], f"tools/list FORWARDE, tools du central relayes -> {tools}")
check(any(r.get("method") == "tools/list" for r in received), "central a recu method=tools/list (forward, plus de catalogue local)")
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
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "get_work_item", "arguments": {}}},
])
errB = by_idB.get(7, {}).get("error", {})
check(errB.get("code") == -32000, f"socket absente -> error -32000 ({errB.get('code')})")

print("--- Test C : methode inconnue -> JSON-RPC error -32601 ---")
by_id3 = run_bridge(base, [{"jsonrpc": "2.0", "id": 9, "method": "bogus/method", "params": {}}])
check(by_id3.get(9, {}).get("error", {}).get("code") == -32601, "methode inconnue -> error -32601")

# F-C138 — l'ancien Test D (bridge expose create_issue+schema en mode architecte) + l'anti-regression
# role-filtering ONT ETE RETIRES : le pont ne hardcode plus de catalogue ni de filtrage par role. Le
# schema create_issue (invariant MA-19 `project` requis) et le filtrage par role sont desormais servis
# par le CENTRAL, couverts cote Elixir par test/pod_socket_test.exs (tools/list = base +
# tools rôle threades, deftool comme source unique) + le conformance test du schema cap-profile.

srv.shutdown()
try:
    os.remove(SOCK_PATH)
except OSError:
    pass
os.rmdir(SOCK_DIR)

print("\n=== VERDICT:", "ALL PASS" if ok else "FAILURES", "===")
sys.exit(0 if ok else 1)
