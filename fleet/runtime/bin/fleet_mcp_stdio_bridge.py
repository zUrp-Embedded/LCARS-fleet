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
# it over stdio (synchronous, fine) and it forwards every tool-call to the REAL central fleet_mcp —
# shared state, off the turn-1 critical path.
#
# IRON LAW: this is the ONE pod comm mechanism (MCP/stdio on the pod side). Not a variant — the bridge
# IS the channel. Central (fleet_mcp) is the state backend, never reached directly by the pod.
# Near-pure transport shim (ZERO fleet logic — the business logic lives in central, on the Elixir
# side): the bridge only terminates the `initialize` handshake locally (pinned protocolVersion) and
# forwards everything else.
#
# IDENTITY IS THE CHANNEL: each pod has ITS OWN AF_UNIX socket, mounted in its sandbox alone. Central
# derives the pod_id from the socket it received on; the bridge injects NO identity into the arguments.
# (The old loopback HTTP transport was shared by every pod and the pod_id was guessable there, so a
# secret capability had to be presented in the args. The per-pod socket closes that hole by
# construction — there is nothing left to present, the channel discriminates.)
#
# Single-threaded transport shim, tools-only (get_work_item IN / submit_result OUT). The push channel
# was removed — 100% pull-driven through `get_work_item`.
#
# ENV:
#   LCARS_FLEET_MCP_SOCKET: path of central's AF_UNIX socket for THIS pod (one socket file per pod,
#                           mounted in the sandbox). REQUIRED.
# (F-C138 — no more LCARS_ROLE: role filtering is done by central from the per-pod socket, the bridge
#  no longer selects any surface locally.)
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


def log(msg):
    print(f"[fleet_mcp_stdio_bridge] {msg}", file=sys.stderr, flush=True)


def send(o):
    line = json.dumps(o) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()


def central_call(method, params):
    # Forwards a JSON-RPC call to central fleet_mcp over the per-pod AF_UNIX socket: one connection PER
    # call (connect → write one line → read one line → close), no state between calls — central accepts
    # connection by connection. Newline-framed: we send exactly `json + "\n"` (json.dumps without indent
    # fits on ONE line, no internal `\n`) and read the response up to the first `\n`. Returns the result
    # field, or raises: missing socket / connection refused / timeout / empty response all surface as an
    # exception, and the tools/call caller turns it into a clean JSON-RPC error for claude — never a
    # silent crash.
    #
    # INSTRUMENTATION (timeout diagnosis): each step (connect/send/readline) is timed and the current one
    # kept in `stage`, so a failure logs WHERE it blocked — a slow `connect` means central is not
    # accepting (busy/serialized acceptor); a slow `readline` means it accepted but is not answering.
    # Without this the pod sees only a mute "timed out", indistinguishable either way. A successful but
    # slow call (>1s) is logged too, with the same per-step breakdown.
    _req_id[0] += 1
    rpc = {"jsonrpc": "2.0", "id": _req_id[0], "method": method, "params": params}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    t0 = time.monotonic()
    stage = "connect"
    try:
        s.connect(SOCKET_PATH)
        t_conn = time.monotonic()
        stage = "send"
        s.sendall((json.dumps(rpc) + "\n").encode())
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




# F-C138 — the bridge carries NO tool catalogue any more: `tools/list` AND `tools/call` are both
# forwarded to central, the SINGLE source of the schemas (`deftool`) and of role filtering (derived from
# the cap-profile, indexed on the per-pod socket = identity through the channel). That is what makes the
# "pure transport shim" claim true: zero logic, zero list, and no Python↔Elixir drift (whose symptom was
# `import_project` being invisible to the pods).
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
            # F-C138 — FORWARD to central (like tools/call), no local catalogue: central is the single
            # source of the schemas (deftool) AND of role filtering (derived from the cap-profile,
            # indexed on the per-pod socket). The bridge knows no tool by heart any more.
            try:
                result = central_call("tools/list", msg.get("params", {}))
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"tools/list forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif method == "tools/call":
            p = msg.get("params", {})
            try:
                # Forward to central AS-IS: NO identity injected into the arguments. Central derives the
                # pod_id from the per-pod socket it received on (identity IS the channel); the wire no
                # longer carries anything to prove. Central's answer goes back untouched.
                result = central_call("tools/call", p)
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})


if __name__ == "__main__":
    main()
