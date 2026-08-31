#!/usr/bin/env python3
# SOURCE: bin/fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# fleet_mcp_stdio_bridge.py — MCP bridge, stdio→AF_UNIX socket (pod ↔ central transport).
#
# WHY IT EXISTS (measured, not assumed): a one-shot claude pod CANNOT connect straight to a networked
# MCP server — at turn 1 the server is still "still connecting", the tools are deferred and the pod
# gives up. Only stdio works (claude spawns the server → synchronous connection → tools inline at
# turn 1). But a per-pod stdio server would hold ISOLATED state. This bridge gets both: claude spawns
# it over stdio and it forwards every tool-call to the REAL central fleet_mcp.
#
# IDENTITY IS THE CHANNEL: each pod has ITS OWN AF_UNIX socket, mounted in its sandbox alone. Central
# derives the pod_id from the socket it received on; the bridge injects NO identity into the arguments
# — there is nothing left to present, the channel discriminates.
#
# ENV:
#   LCARS_FLEET_MCP_SOCKET: path of central's AF_UNIX socket for THIS pod (one socket file per pod,
#                           mounted in the sandbox). REQUIRED.
# Protocol: newline-framed JSON-RPC on stdin/stdout (claude side); the same newline-framed JSON-RPC on
# the AF_UNIX socket (central side) — one request = one line, one response = one line.
import json
import os
import socket
import sys
import time

SOCKET_PATH = os.environ.get("LCARS_FLEET_MCP_SOCKET", "")
PROTO = "2024-11-05"
_req_id = [1000]
# connect/send borne le cas « central MORT », readline le cas « central OCCUPE » — cf. central_call.
CONNECT_TIMEOUT = float(os.environ.get("LCARS_MCP_CONNECT_TIMEOUT", "30"))
READ_TIMEOUT = float(os.environ.get("LCARS_MCP_READ_TIMEOUT", "600"))


def log(msg):
    print(f"[fleet_mcp_stdio_bridge] {msg}", file=sys.stderr, flush=True)


def send(o):
    line = json.dumps(o) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()


def central_call(method, params):
    # Le framing par saut de ligne tient parce que `json.dumps` SANS indent produit UNE ligne, sans
    # `\n` interne : on envoie `json + "\n"` et on lit jusqu'au premier `\n`.
    #
    # `stage` porte l'etape en cours pour que l'echec dise OU il a bloque : un `connect` lent = central
    # n'accepte pas ; un `readline` lent = il a accepte et ne repond pas. Sans elle, le pod ne voit
    # qu'un « timed out » muet, identique dans les deux cas.
    #
    # ⚠ READ_TIMEOUT DOIT EXCEDER LE PIRE CAS COMPOSE DE CENTRAL, jamais l'inverse : sous la borne
    # reelle, une mutation lente rend une ERREUR a l'agent pendant que son effet s'acheve, et le
    # re-envoi de l'agent cree un DOUBLON. L'ancien timeout unique de 30 s etait sous la borne — le
    # seul chemin publish a ete mesure a 165 s.
    _req_id[0] += 1
    rpc = {"jsonrpc": "2.0", "id": _req_id[0], "method": method, "params": params}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(CONNECT_TIMEOUT)
    t0 = time.monotonic()
    stage = "connect"
    try:
        s.connect(SOCKET_PATH)
        t_conn = time.monotonic()
        stage = "send"
        s.sendall((json.dumps(rpc) + "\n").encode())
        s.settimeout(READ_TIMEOUT)
        t_send = time.monotonic()
        stage = "readline"
        resp_line = s.makefile("rb").readline()
        t_recv = time.monotonic()
        if t_recv - t0 > 1.0:
            log(f"central_call {method} SLOW {t_recv-t0:.2f}s "
                f"(connect={t_conn-t0:.3f}s send={t_send-t_conn:.3f}s readline={t_recv-t_send:.3f}s)")
    except Exception as e:
        log(f"central_call {method} FAILED at stage='{stage}' after {time.monotonic()-t0:.2f}s: {e!r}")
        raise
    finally:
        s.close()
    if not resp_line:
        raise RuntimeError("central: empty response (connection closed without a line)")
    payload = json.loads(resp_line.decode())
    if "error" in payload:
        raise RuntimeError(f"central error: {payload['error']}")
    return payload.get("result", {})




# F-C138 — le bridge ne porte AUCUN catalogue d'outils : central est la source unique des schemas et
# du filtrage par role. Zero derive Python↔Elixir.
def main():
    if not SOCKET_PATH:
        log("FATAL: LCARS_FLEET_MCP_SOCKET unset — the bridge has no central socket to reach")
        sys.exit(1)
    log(f"start → central socket {SOCKET_PATH}")

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
                "serverInfo": {"name": "fleet-stdio-bridge", "version": "0.2.0"}}})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            try:
                result = central_call("tools/list", msg.get("params", {}))
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"tools/list forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif method == "tools/call":
            p = msg.get("params", {})
            try:
                # AS-IS : aucune identite injectee dans les arguments, central la derive de la socket.
                result = central_call("tools/call", p)
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})


if __name__ == "__main__":
    main()
