#!/usr/bin/env python3
# SOURCE: fleet/runtime/test/test_fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation run 2026-05-27)
# STARDATE: 2026.147
# STATUS: regression test — MCP stdio bridge (bin/fleet_mcp_stdio_bridge.py), central STUBBED (AF_UNIX
#         socket).
#
# Covers (SHIM test, central stubbed on a local AF_UNIX socket): the MCP stdio handshake
# (initialize/tools/list), tools/call forwarded to central over the per-pod socket, identity
# NON-injection (arguments are forwarded AS-IS — no `_lcars_*` key, even with LCARS_POD_ID in the env),
# JSON-RPC -32601 on an unknown method, and JSON-RPC -32000 when the socket is unreachable (no silent
# crash).
# Does NOT cover (= supervised e2e gates): the real central fleet_mcp (Elixir round-trip), execution in
# a real bwrap pod. Nor any tool SCHEMA: since F-C138 the bridge holds no catalogue, so there is nothing
# schema-shaped here to test — see the Elixir side (test/pod_socket_test.exs).
# Run: python3 fleet/runtime/test/test_fleet_mcp_stdio_bridge.py  (exit 0 = pass).
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

# Central stubbed on a local AF_UNIX socket (standing in for Fleet.MCP.PodSocketAcceptor). The bridge
# does connect→one line→one line→close PER call, so each connection is one handler. Newline-framed (like
# `{:packet, :line}` on the Elixir side): read ONE line (readline → up to the `\n`), answer ONE line
# (`json + "\n"`). The response is the full JSON-RPC envelope with `result` (the bridge extracts the
# `result` field). `_echo_args` echoes the forwarded arguments back → that is what proves NO identity was
# injected into them.


class Stub(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline()
        if not line:
            return
        body = json.loads(line.decode())
        received.append(body)
        # F-C138 — central is now the source of tools/list (role filtering, server-side) and the bridge
        # FORWARDS it (like tools/call), so we stub a DISTINCT tools/list response to prove the relay.
        # tools/call returns the echo instead (identity non-injection, the heart of R9).
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


# AF_UNIX paths are capped at ~108 bytes — a short tmp dir is plenty.
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


print("--- Test A: handshake + tools + forward over the socket (tools-only mode) ---")
# LCARS_POD_ID IS set in the env, but the bridge no longer reads it: it MUST NOT show up in the
# forwarded args (identity comes from the channel, central-side — never from the wire again).
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
check("experimental" not in init.get("capabilities", {}), "initialize -> no experimental capability")
tools = sorted(t["name"] for t in by_id.get(2, {}).get("result", {}).get("tools", []))
# F-C138 — tools/list is FORWARDED to central (no local catalogue): the bridge relays central's list
# as-is, and central did RECEIVE the tools/list method.
check(tools == ["get_work_item", "submit_result"], f"tools/list FORWARDED, central's tools relayed -> {tools}")
check(any(r.get("method") == "tools/list" for r in received), "central received method=tools/list (forward, no local catalogue)")
check(by_id.get(3, {}).get("result", {}).get("task", {}).get("id") == "T1", "tools/call -> central's result returned")
check(received and received[-1].get("method") == "tools/call", "central received method=tools/call")
# Identity NON-injection: the arguments reach central EXACTLY as claude sent them, with no `_lcars_*`
# key added (even with LCARS_POD_ID in the env). That is the heart of the R9 fix.
fwd_args = received[-1].get("params", {}).get("arguments", {}) if received else {}
lcars_keys = sorted(k for k in fwd_args if k.startswith("_lcars_"))
check(lcars_keys == [], f"NO _lcars_* identity injected (forwarded args: {sorted(fwd_args)})")
check(fwd_args == {"foo": "bar"}, f"arguments forwarded AS-IS ({fwd_args})")

print("--- Test B: unreachable socket -> JSON-RPC error -32000 (no silent crash) ---")
nogo = {"LCARS_FLEET_MCP_SOCKET": os.path.join(SOCK_DIR, "absente.sock")}
by_idB = run_bridge(nogo, [
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "get_work_item", "arguments": {}}},
])
errB = by_idB.get(7, {}).get("error", {})
check(errB.get("code") == -32000, f"missing socket -> error -32000 ({errB.get('code')})")

print("--- Test C: unknown method -> JSON-RPC error -32601 ---")
by_id3 = run_bridge(base, [{"jsonrpc": "2.0", "id": 9, "method": "bogus/method", "params": {}}])
check(by_id3.get(9, {}).get("error", {}).get("code") == -32601, "unknown method -> error -32601")

# F-C138 — the old Test D (bridge exposes create_issue+schema in architect mode) and the role-filtering
# anti-regression WERE REMOVED: the bridge hardcodes neither a catalogue nor role filtering any more.
# The create_issue schema (MA-19 invariant: `project` required) and role filtering are served by CENTRAL
# now, covered on the Elixir side by test/pod_socket_test.exs (tools/list = base + role tools, deftool as
# the single source) plus the cap-profile schema conformance test.

srv.shutdown()
try:
    os.remove(SOCK_PATH)
except OSError:
    pass
os.rmdir(SOCK_DIR)

print("\n=== VERDICT:", "ALL PASS" if ok else "FAILURES", "===")
sys.exit(0 if ok else 1)
