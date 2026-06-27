#!/usr/bin/env python3
# SOURCE: bin/fleet_mcp_stdio_bridge.py
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# fleet_mcp_stdio_bridge.py — pont MCP stdio→socket AF_UNIX (transport pod ↔ central).
#
# RAISON D'ÊTRE (vérifié empiriquement) : un pod claude one-shot NE PEUT PAS se connecter en direct à
# un serveur MCP réseau (au turn-1 le serveur est encore "still connecting", tools déférés → abandon).
# Seul stdio marche (claude spawne le serveur → connexion synchrone → tools inline turn-1). Mais un
# serveur stdio par-pod aurait un état ISOLÉ. Ce pont résout les deux : claude le spawne en stdio
# (synchrone, OK), et lui forwarde chaque tool-call vers le VRAI fleet_mcp central, état partagé, hors
# du chemin critique turn-1.
#
# IRON LAW : c'est le mécanisme de comm pod UNIQUE (MCP/stdio côté pod). Pas une variante — le pont
# EST le canal. Le central (fleet_mcp) est le backend d'état, jamais joint en direct par le pod.
# Transport-shim pur (zéro logique fleet) : la logique vit côté Elixir central.
#
# IDENTITÉ = LE CANAL : chaque pod a SA propre socket AF_UNIX, montée dans son seul sandbox. Le central
# dérive le pod_id de la socket sur laquelle il reçoit ; le pont n'injecte plus AUCUNE identité dans les
# arguments. (L'ancien transport HTTP loopback était partagé par tous les pods, le pod_id y était
# devinable → il fallait alors présenter une capability secrète dans les args ; la socket per-pod ferme
# ce trou par construction — il n'y a plus rien à présenter, le canal discrimine.)
#
# Transport-shim mono-thread, tools-only (get_task IN / submit_result OUT). Le push channel a été
# retiré — drive 100% par pull `get_task`.
#
# ENV :
#   LCARS_FLEET_MCP_SOCKET : chemin de la socket AF_UNIX du central pour CE pod (un fichier socket
#                            per-pod, monté dans le sandbox). REQUIS.
#   LCARS_ROLE             : rôle du pod ; sélectionne LOCALEMENT sa surface de tools
#                            (BASE_TOOLS, + ARCHITECT_TOOLS si "architect"). OPT.
# Protocole : JSON-RPC newline-framed sur stdin/stdout (côté claude) ; même JSON-RPC newline-framed sur
# la socket AF_UNIX (côté central) — une requête = une ligne, une réponse = une ligne.
import json
import os
import socket
import sys
import time

SOCKET_PATH = os.environ.get("LCARS_FLEET_MCP_SOCKET", "")
ROLE = os.environ.get("LCARS_ROLE", "")
PROTO = "2024-11-05"
_req_id = [1000]


def log(msg):
    print(f"[fleet_mcp_stdio_bridge] {msg}", file=sys.stderr, flush=True)


def send(o):
    line = json.dumps(o) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()


def central_call(method, params):
    # Forwarde un appel JSON-RPC au fleet_mcp central via la socket AF_UNIX per-pod : une connexion
    # PAR appel (connect → envoie une ligne → lit une ligne → close), sans état entre appels — le
    # central accepte connexion par connexion. Newline-framed : on envoie exactement `json + "\n"`
    # (json.dumps sans indent tient sur UNE ligne, aucun `\n` interne) et on lit la réponse jusqu'au
    # premier `\n`. Retourne le champ result (ou lève : socket absente / connexion refusée / timeout /
    # réponse vide remontent comme exception — l'appelant tools/call la traduit en erreur JSON-RPC
    # propre vers claude, jamais un crash silencieux).
    #
    # INSTRUMENTATION (diagnostic timeout) : chaque étape (connect/send/readline) est chronométrée et
    # l'étape courante gardée dans `stage`. Un échec loggue DONC où ça a bloqué — `connect` lent = le
    # central n'accepte pas la connexion (accepteur occupé/sérialisé) ; `readline` lent = il a accepté
    # mais ne répond pas. Sans ça le pod ne voit qu'un « timed out » muet, indistinguable. Un appel
    # réussi mais lent (>1s) est aussi loggué avec le détail par étape.
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
            log(f"central_call {method} LENT {t_recv-t0:.2f}s "
                f"(connect={t_conn-t0:.3f}s send={t_send-t_conn:.3f}s readline={t_recv-t_send:.3f}s)")
    except Exception as e:
        log(f"central_call {method} ECHEC etape='{stage}' apres {time.monotonic()-t0:.2f}s : {e!r}")
        raise
    finally:
        s.close()
    if not resp_line:
        raise RuntimeError("central: réponse vide (connexion fermée sans ligne)")
    payload = json.loads(resp_line.decode())
    if "error" in payload:
        raise RuntimeError(f"central error: {payload['error']}")
    return payload.get("result", {})


# Surface de tools du pod = DÉRIVÉE de son rôle (LCARS_ROLE). Principe : la PRÉSENCE EST
# l'AUTORISATION — un pod ne voit (donc ne peut lister, chercher via ToolSearch, ni appeler) QUE
# les tools que son rôle EST. Deny-par-défaut par construction : absent de la surface du rôle =
# inexistant pour lui (rien à interdire, rien à ré-autoriser). Pas de champ allowlist : le rôle EST
# la surface. (alwaysLoad — visibilité hors-déferral — est porté par .mcp-fleet.json.)

# Base — tout pod EST un task-worker : pull get_task IN / push submit_result OUT.
BASE_TOOLS = [
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

# Délégateur — l'ARCHITECTE EST celui qui ONBOARDE (create_project), DÉLÈGUE (create_ticket) et SUIT
# l'avancement (get_ticket_status). Ces tools n'existent QUE dans son monde ; un worker/juge ne les
# voit pas du tout. tools/call forwarde au central (qui porte la logique : assignee=humain, etc.).
ARCHITECT_TOOLS = [
    {
        "name": "create_ticket",
        # MA-19 : schéma SYNCHRONISÉ avec le central (apps/fleet_mcp/.../pod_tools.ex `create_ticket`).
        # `project` est OBLIGATOIRE côté central (refus structurel sans lui — F-TICKET-ROUTE-FOOTGUN : pas de
        # routage par défaut, jamais de misroute silencieux). Le bridge l'exposait SANS `project` → l'arch
        # lisait un schéma stale, omettait `project`, et le central refusait. Toute évolution du schéma
        # central se reflète ICI (sync cross-langage Python↔Elixir manuelle — outil LAN, pas de dérivation).
        "description": "Delegue une brique d'implementation a la fleet LCARS : cree un ticket (issue forge) "
                       "pret pour la livraison forge-native (engineer -> PR -> review -> merge). Utilise-le pour "
                       "DELEGUER plutot que de coder toi-meme (la fleet livre mieux et preserve ton contexte). "
                       "`brief` = le mandat clair pour l'engineer. `project` = le repo `owner/name` OU LIVRER, "
                       "OBLIGATOIRE : le repo retourne par `create_project`, ou le projet designe par l'humain. "
                       "Sans `project`, le ticket est REFUSE (jamais de misroute silencieux vers un autre projet).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "brief": {"type": "string"},
                "project": {"type": "string"},
            },
            "required": ["title", "brief", "project"],
        },
    },
    {
        "name": "create_project",
        "description": "Demarre un NOUVEAU projet : cree le repo forge + les 2 dossiers dual-dir "
                       "(/home/projects/<name> sur main, /home/projects.work/<name> sur work/ops) + le "
                       "scaffold de base, et le pousse. Utilise-le quand l'humain veut LANCER un projet "
                       "neuf. `name` = slug kebab-case. Le projet cree devient la cible de delegation : "
                       "enchaine ensuite create_ticket pour l'implementation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "pitch": {"type": "string"},
                "description": {"type": "string"},
            },
            "required": ["name"],
        },
    },
    {
        "name": "get_ticket_status",
        "description": "Consulte l'etat d'un ticket delegue (issue + PR liee) du projet courant : "
                       "issue ouverte/fermee, PR mergee ou non, verdicts de review par juge. Utilise-le "
                       "pour SUIVRE un ticket avant d'enchainer — ex: valider la livraison (PR mergee) du "
                       "ticket N AVANT de poster le ticket N+1. `number` = le numero d'issue (ex: 1).",
        "inputSchema": {
            "type": "object",
            "properties": {"number": {"type": "integer"}},
            "required": ["number"],
        },
    },
]

# La surface = dérivée du rôle, point. Un nouveau tool puissant n'est servi à personne tant qu'il
# n'est pas rattaché à un rôle ; un nouveau rôle n'a que sa base tant qu'on ne lui en grant pas plus.
TOOLS = BASE_TOOLS + (ARCHITECT_TOOLS if ROLE == "architect" else [])


def main():
    if not SOCKET_PATH:
        log("FATAL: LCARS_FLEET_MCP_SOCKET non défini — le pont n'a pas de socket central à joindre")
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
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            p = msg.get("params", {})
            try:
                # Forward au central TEL QUEL : AUCUNE identité injectée dans les arguments. Le central
                # dérive le pod_id de la socket per-pod sur laquelle il reçoit (l'identité EST le canal) ;
                # le wire ne porte plus rien à prouver. La réponse du central est renvoyée telle quelle.
                result = central_call("tools/call", p)
                send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:
                log(f"forward fail: {e}")
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method {method}"}})


if __name__ == "__main__":
    main()
