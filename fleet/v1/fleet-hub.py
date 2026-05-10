#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-hub.py
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: HUB             | SUBSYSTEM: FLEET / DISPLAY      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Fleet status hub — real-time REST server.                |
#     |  Exposes handoff state and spool inbox counts via REST.   |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Serveur REST lecture-seule pour l'état de la fleet.
#     Lit les handoffs et les inbox spool, expose via HTTP.
#     Endpoints : /state, /state/<id>, /spool, /spool/<role>.
#
#     [EN]
#     NAME
#         fleet-hub.py — fleet status REST server (read-only)
#
#     SYNOPSIS
#         fleet-hub.py [--port PORT] [--handoff-dir DIR] [--spool-inbox DIR]
#
#     DESCRIPTION
#         Lightweight HTTP server that exposes fleet state in JSON:
#         - GET /state: all instances' handoff STATE fields
#         - GET /state/<id>: single instance state
#         - GET /spool: inbox message counts per role
#         - GET /spool/<role>: inbox count for one role
#         Read-only — never modifies any fleet state. Designed for
#         fleet-monitor.py TUI and future webGUI consumption.
#
#     INTERFACE
#         Ring:    1 (support)
#         Input:   $FLEET_HANDOFFS/*-handoff.md, /var/spool/fleet/inbox/
#         Output:  HTTP JSON responses on configured port
#         JSON:    all endpoints return JSON
#
#     EXIT CODES
#         0    Normal shutdown
#         1    Port already in use or startup error
#
#     EXAMPLES
#         python3 fleet-hub.py
#         python3 fleet-hub.py --port 8080
#
#     SEE ALSO
#         fleet-monitor.py, fleet-state.sh, fleet-launch.sh
#
# --- END HEADER ---

import argparse
import http.server
import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

import yaml


STALE_MINUTES = 30

# Runtime fleet.yaml — single source of truth, no fallback
_FLEET_YAML_PATH = Path("/local/LCARS/fleet/fleet.yaml")


def _load_fleet_yaml() -> dict:
    if not _FLEET_YAML_PATH.exists():
        print(f"ERREUR : {_FLEET_YAML_PATH} introuvable — runtime non deploye", file=sys.stderr)
        sys.exit(1)
    try:
        with _FLEET_YAML_PATH.open(encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        print(f"ERREUR : impossible de lire {_FLEET_YAML_PATH} : {e}", file=sys.stderr)
        sys.exit(1)


def _build_instance_files(fleet: dict) -> dict[str, str]:
    instances = fleet.get("instances", []) or []
    return {
        inst["role"]: f"{inst['role']}-handoff.md"
        for inst in instances
        if "role" in inst
    }


_FLEET_DATA = _load_fleet_yaml()
_FLEET_YAML_MTIME: float = _FLEET_YAML_PATH.stat().st_mtime

# Fichiers d'état par instance — chargés depuis fleet.yaml (Blueprint = seule vérité topologique)
INSTANCE_FILES: dict[str, str] = _build_instance_files(_FLEET_DATA)


def _maybe_reload_topology():
    """IEC 61508: reload fleet.yaml if mtime changed since last load."""
    global _FLEET_DATA, _FLEET_YAML_MTIME, INSTANCE_FILES
    try:
        current_mtime = _FLEET_YAML_PATH.stat().st_mtime
    except (OSError, NameError):
        return
    if current_mtime != _FLEET_YAML_MTIME:
        _FLEET_DATA = _load_fleet_yaml()
        INSTANCE_FILES = _build_instance_files(_FLEET_DATA)
        _FLEET_YAML_MTIME = current_mtime
        print(f"[fleet-hub] fleet.yaml reloaded (mtime changed)", file=sys.stderr)

ACTIONS_RE = re.compile(
    r'## ACTIONS\n(.*?)(?=\n## |\Z)',
    re.DOTALL
)


def parse_state(text: str, source_file: str) -> dict:
    # Localiser ## STATE (indépendant de l'ordre des champs)
    m = re.search(r'^## STATE\s*$', text, re.MULTILINE)
    if not m:
        return {
            "status": "unknown",
            "stale": True,
            "error": "bloc ## STATE absent ou malformé",
            "file": source_file,
        }

    # Extraire le bloc jusqu'à la prochaine section ## ou fin de fichier
    block_start = m.end()
    next_section = re.search(r'^## ', text[block_start:], re.MULTILINE)
    block = text[block_start: block_start + next_section.start()] if next_section else text[block_start:]

    # Parser les champs clé: valeur — ordre libre
    fields: dict[str, str] = {}
    for line in block.splitlines():
        fm = re.match(r'^(\w+):\s*(.+)$', line.strip())
        if fm:
            fields[fm.group(1)] = fm.group(2).strip()

    date_str = fields.get("date", "")
    ref      = fields.get("ref", "-")
    action   = fields.get("action", "unknown")
    status   = fields.get("status", "unknown")
    blocker  = fields.get("blocker", "none")
    waiting  = fields.get("waiting", "none")
    notify   = fields.get("notify", "none")

    stale = True
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d %H:%M")
        stale = (datetime.now() - dt) > timedelta(minutes=STALE_MINUTES)
    except ValueError:
        pass

    # Actions en attente (lignes [ ])
    pending_actions = []
    am = ACTIONS_RE.search(text)
    if am:
        for line in am.group(1).splitlines():
            line = line.strip()
            if line.startswith("[ ]"):
                pending_actions.append(line[3:].strip())

    # Compter les entrées complétées dans ## DONE
    done_count = 0
    dm = re.search(r'^## DONE\s*$', text, re.MULTILINE)
    if dm:
        done_start = dm.end()
        next_sec = re.search(r'^## ', text[done_start:], re.MULTILINE)
        done_block = text[done_start: done_start + next_sec.start()] if next_sec else text[done_start:]
        done_count = len(re.findall(r'^### ', done_block, re.MULTILINE))

    return {
        "date":            date_str,
        "ref":             ref,
        "action":          action,
        "status":          status,
        "blocker":         blocker,
        "waiting":         waiting,
        "notify":          notify,
        "stale":           stale,
        "pending_actions": pending_actions,
        "done_count":      done_count,
        "file":            source_file,
    }


def read_handoff(handoff_dir: Path, filename: str) -> dict:
    path = handoff_dir / filename
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return {"status": "absent", "stale": True, "file": filename}
    except OSError as e:
        return {"status": "error", "stale": True, "error": str(e), "file": filename}
    return parse_state(text, filename)


def count_spool_inbox(spool_inbox_root: Path, role: str) -> int:
    """Count messages in /var/spool/fleet/inbox/<role>/ (excluding .consumed/)."""
    inbox_dir = spool_inbox_root / role
    if not inbox_dir.exists():
        return 0
    try:
        return sum(
            1 for f in inbox_dir.iterdir()
            if f.is_file() and f.parent.name != ".consumed"
        )
    except OSError:
        return 0


class FleetHubHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        _maybe_reload_topology()
        path = self.path.rstrip("/")

        if path == "/state":
            data = {
                iid: read_handoff(self.server.handoff_dir, fname)
                for iid, fname in INSTANCE_FILES.items()
            }
            self._send_json(data)

        elif path.startswith("/state/"):
            iid = path[len("/state/"):]
            if iid not in INSTANCE_FILES:
                self._send_error(404, f"Instance '{iid}' inconnue. Instances : {list(INSTANCE_FILES)}")
                return
            fname = INSTANCE_FILES[iid]
            self._send_json(read_handoff(self.server.handoff_dir, fname))

        elif path == "/spool":
            data = {
                role: count_spool_inbox(self.server.spool_inbox_root, role)
                for role in INSTANCE_FILES
            }
            self._send_json(data)

        elif path.startswith("/spool/"):
            role = path[len("/spool/"):]
            if role not in INSTANCE_FILES:
                self._send_error(404, f"Rôle '{role}' inconnu. Rôles : {list(INSTANCE_FILES)}")
                return
            self._send_json({role: count_spool_inbox(self.server.spool_inbox_root, role)})

        else:
            self._send_error(404, "Endpoints : GET /state, GET /state/<id>, GET /spool, GET /spool/<role>")

    def _send_json(self, data: dict):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "null")  # SEC-05: block browser cross-origin requests
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code: int, message: str):
        body = json.dumps({"error": message}, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "null")  # SEC-05
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # IEC 61508: log access to file instead of suppressing
        try:
            with open("/home/fleet-state/fleet-hub-access.log", "a", encoding="utf-8") as f:
                f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {self.client_address[0]} {format % args}\n")
        except OSError:
            pass


class FleetHubServer(http.server.HTTPServer):
    def __init__(self, addr, handler, handoff_dir: Path, spool_inbox_root: Path):
        super().__init__(addr, handler)
        self.handoff_dir = handoff_dir
        self.spool_inbox_root = spool_inbox_root


def main():
    parser = argparse.ArgumentParser(description="fleet-hub v5 — REST read-only sur les fichiers handoff + spool inbox")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--handoff-dir", default=os.environ.get("FLEET_HANDOFFS", "/home/projects.work/LCARS/work/handoffs"))
    parser.add_argument("--spool-inbox", default="/var/spool/fleet/inbox")
    args = parser.parse_args()

    handoff_dir = Path(args.handoff_dir)
    if not handoff_dir.exists():
        print(f"Erreur : {handoff_dir} introuvable", file=sys.stderr)
        sys.exit(1)

    spool_inbox_root = Path(args.spool_inbox)

    server = FleetHubServer(
        ("127.0.0.1", args.port),
        FleetHubHandler,
        handoff_dir,
        spool_inbox_root,
    )
    print(f"fleet-hub v5 sur http://127.0.0.1:{args.port}")
    print(f"  GET /state              — instances")
    print(f"  GET /state/<id>         — une instance")
    print(f"  GET /spool              — inbox spool counts")
    print(f"  GET /spool/<role>       — inbox count pour un rôle")
    print(f"  Handoff dir  : {handoff_dir}")
    print(f"  Spool inbox  : {spool_inbox_root}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nArrêt.")


if __name__ == "__main__":
    main()
