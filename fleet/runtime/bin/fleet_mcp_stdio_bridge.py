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
# Transport-shim mono-thread, tools-only (get_task IN / submit_result OUT). Le push channel
# (ChannelHTTP) a été retiré au purge ADR-G C5.1 — drive 100% par pull `get_task` (F158).
#
# ENV :
#   LCARS_FLEET_MCP_URL          : endpoint MCP central tools (ex http://localhost:PORT/mcp). REQUIS.
#   LCARS_POD_ID                 : identité pod (corrélation des tool calls). OPT.
# Protocole : JSON-RPC newline-delimited sur stdin/stdout (côté claude) ; POST JSON-RPC (côté central).
import json
import os
import sys
import urllib.request

CENTRAL_URL = os.environ.get("LCARS_FLEET_MCP_URL", "")
POD_ID = os.environ.get("LCARS_POD_ID", "")
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
    if not CENTRAL_URL:
        log("FATAL: LCARS_FLEET_MCP_URL non défini — le pont n'a pas de central à joindre")
        sys.exit(1)
    log(f"start → central {CENTRAL_URL}")

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
                # Injecte l'identité du pod (pod_id + rôle) dans les arguments forwardés : corrélation
                # côté central + résolution du compte de rôle (ex create_ticket → token du rôle appelant).
                if POD_ID or ROLE:
                    args = dict(p.get("arguments") or {})
                    if POD_ID:
                        args["_lcars_pod_id"] = POD_ID
                    if ROLE:
                        args["_lcars_role"] = ROLE
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
