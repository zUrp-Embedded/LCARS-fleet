#!/usr/bin/env python3
# SOURCE: bin/fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# fleet_mcp_stdio_bridge.py — pont MCP stdio→HTTP (R-CORE.comm inc3c).
#
# RAISON D'ÊTRE (vérifié empiriquement, cf corpus #0_ref_mcp-tool-deferral-oneshot.md §7-addendum) :
# un pod claude one-shot NE PEUT PAS se connecter en direct à un serveur MCP HTTP (au turn-1 le
# serveur est encore "still connecting", tools déférés → abandon). Seul stdio marche (claude spawne
# le serveur → connexion synchrone → tools inline turn-1). Mais un serveur stdio par-pod a un état
# ISOLÉ. Ce pont résout les deux : claude le spawne en stdio (synchrone, OK), et lui forwarde chaque
# tool-call vers le VRAI fleet_mcp central en HTTP (état partagé, hors du chemin critique turn-1).
#
# IRON LAW : c'est le mécanisme de comm pod UNIQUE (MCP/stdio côté pod). Pas une variante — le pont
# EST le canal. Le central HTTP (fleet_mcp, ExMCP) est le backend d'état, jamais joint en direct par
# le pod. Transport-shim pur (zéro logique fleet) : la logique vit côté Elixir central.
#
# U2 — Extension push channel notifications (vendor natif claude REPL) :
# Le pont déclare `capabilities.experimental['claude/channel']` et expose en plus du forward
# request/response (tools) une thread daemon qui long-poll `LCARS_FLEET_MCP_CHANNEL_URL/channels/
# <POD_ID>/poll` et émet sur stdout `notifications/claude/channel` quand le central a un push.
# Cohérent doctrine "MCP en priorité pour data plane, send-keys uniquement pour slash commands".
#
# ENV :
#   LCARS_FLEET_MCP_URL          : endpoint MCP central tools (ex http://localhost:PORT/mcp). REQUIS.
#   LCARS_FLEET_MCP_CHANNEL_URL  : endpoint HTTP custom channel push (ex http://localhost:PORT2). OPT.
#                                  Sans cette var, pas de thread channel (mode legacy tools-only).
#   LCARS_POD_ID                 : identité pod (corrélation tools + routing channel). OPT.
# Protocole : JSON-RPC newline-delimited sur stdin/stdout (côté claude) ; POST JSON-RPC (côté central).
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

CENTRAL_URL = os.environ.get("LCARS_FLEET_MCP_URL", "")
CHANNEL_URL = os.environ.get("LCARS_FLEET_MCP_CHANNEL_URL", "")
POD_ID = os.environ.get("LCARS_POD_ID", "")
PROTO = "2024-11-05"
_req_id = [1000]

# U2 — Lock stdout : thread channel + main thread écrivent tous deux sur sys.stdout. Sans lock,
# JSON-RPC frames pourraient s'interleave (corruption). Le lock garantit qu'une ligne JSON est
# écrite atomiquement avant qu'une autre ne commence.
_stdout_lock = threading.Lock()


def log(msg):
    print(f"[fleet_mcp_stdio_bridge] {msg}", file=sys.stderr, flush=True)


def send(o):
    line = json.dumps(o) + "\n"
    with _stdout_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def central_call(method, params):
    # Forwarde un appel JSON-RPC au fleet_mcp central (HTTP). Retourne le champ result (ou lève).
    _req_id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _req_id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(
        CENTRAL_URL, data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode())
    if "error" in payload:
        raise RuntimeError(f"central error: {payload['error']}")
    return payload.get("result", {})


def channel_poll_loop():
    # U2 — Thread daemon : long-poll fleet_mcp.ChannelHTTP `/channels/<POD_ID>/poll?timeout=30`,
    # émet chaque notification reçue en `notifications/claude/channel` sur stdout (format natif
    # vendor claude REPL — la REPL l'enqueue avec priority:next, isMeta:true, skipSlashCommands:true).
    #
    # Backoff exponentiel sur erreurs réseau (cap 30s). Loop infini tant que le process vit.
    url_base = CHANNEL_URL.rstrip("/")
    poll_url = f"{url_base}/channels/{POD_ID}/poll?timeout=30"
    err_streak = 0

    while True:
        try:
            req = urllib.request.Request(poll_url, method="GET")
            with urllib.request.urlopen(req, timeout=35) as resp:
                payload = json.loads(resp.read().decode())

            err_streak = 0
            notifs = payload.get("notifications", []) if isinstance(payload, dict) else []

            for notif in notifs:
                content = notif.get("content")
                meta = notif.get("meta", {})
                if not isinstance(content, str) or content == "":
                    log(f"channel_poll: invalid notif (no content): {notif}")
                    continue

                send({
                    "jsonrpc": "2.0",
                    "method": "notifications/claude/channel",
                    "params": {"content": content, "meta": meta},
                })

        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
            err_streak += 1
            backoff = min(2 ** err_streak, 30)
            log(f"channel_poll error (streak={err_streak}): {e} — backoff {backoff}s")
            time.sleep(backoff)
        except Exception as e:
            err_streak += 1
            backoff = min(2 ** err_streak, 30)
            log(f"channel_poll unexpected: {type(e).__name__}: {e} — backoff {backoff}s")
            time.sleep(backoff)


# Tools exposés au pod = mirroir des tools fleet (get_task IN / submit_result OUT). alwaysLoad est
# porté par .mcp-fleet.json (config serveur), pas ici.
TOOLS = [
    {
        "name": "get_task",
        "description": "Recupere ta prochaine tache aupres du fleet LCARS. Retourne {\"done\":true} "
                       "quand il n'y a plus de tache (tu t'arretes alors), sinon {\"done\":false,\"task\":{...}}.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "submit_result",
        "description": "Retourne le resultat structure d'une tache au fleet LCARS, dans `payload`.",
        "inputSchema": {
            "type": "object",
            "properties": {"payload": {"type": "object"}},
            "required": ["payload"],
        },
    },
]


def main():
    if not CENTRAL_URL:
        log("FATAL: LCARS_FLEET_MCP_URL non défini — le pont n'a pas de central à joindre")
        sys.exit(1)
    log(f"start → central {CENTRAL_URL}")

    # U2 — Démarre thread channel SSI LCARS_FLEET_MCP_CHANNEL_URL configuré ET POD_ID présent.
    # Mode legacy tools-only (pas de channel) si CHANNEL_URL absent → comportement inchangé.
    if CHANNEL_URL and POD_ID:
        log(f"channel poll → {CHANNEL_URL} for pod_id={POD_ID}")
        t = threading.Thread(target=channel_poll_loop, daemon=True, name="channel_poll")
        t.start()
    elif CHANNEL_URL and not POD_ID:
        log("channel URL set but POD_ID empty — channel push disabled (would broadcast to no one)")

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
            # U2 — Déclare `capabilities.experimental.claude.channel` (alongside tools) pour signaler
            # à claude REPL qu'il peut recevoir des `notifications/claude/channel` de ce server.
            # Le pod n'a rien à coder côté SP — le REPL enqueue automatiquement.
            capabilities = {"tools": {}}
            if CHANNEL_URL and POD_ID:
                capabilities["experimental"] = {"claude/channel": {}}

            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": PROTO, "capabilities": capabilities,
                "serverInfo": {"name": "fleet-stdio-bridge", "version": "0.2.0"}}})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            p = msg.get("params", {})
            try:
                # Injecte l'identité du pod dans les arguments forwardés (corrélation côté central).
                if POD_ID:
                    args = dict(p.get("arguments") or {})
                    args["_lcars_pod_id"] = POD_ID
                    p = {**p, "arguments": args}
                # Forward au central (même method/params enrichis) → réponse central renvoyée telle quelle.
                result = central_call("tools/call", p)
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})


if __name__ == "__main__":
    main()
