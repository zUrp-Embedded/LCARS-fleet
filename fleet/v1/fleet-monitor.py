#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: fleet-monitor.py
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
#     | MODULE: MONITOR         | SUBSYSTEM: FLEET / IPC          |
#     | LICENSE: AGPL-3         | STARDATE: 2026.091              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Watches handoffs, dispatches wake signals.               |
#     |  Polls notify fields and calls wake-instance.sh.          |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     fleet-monitor.py v5 — dashboard terminal pour la flotte WSL
#
#     Lit l'état des instances via fleet-hub.py (GET /state).
#     Surveille les spool inbox via fleet-hub.py (GET /spool).
#     Rafraîchissement automatique toutes les 2 secondes.
#     Implémenté avec rich.layout + rich.live.
#
#     Prérequis : fleet-hub.py doit tourner sur le même host.
#
#     [EN]
#     fleet-monitor.py v5 — Watches handoffs, dispatches wake signals.
#     Polls notify fields and spool inbox counts, calls wake-instance.sh.
#

#
#     **Date** : 2026-03-17
#     **Dernière révision** : 2026-03-19
#     **Statut** : port v3 → v5 — spool wake, builder→reviewer, fleet v5 roles
#     **Référencé par** : fleet-launch.sh
#     **Dérivé de** : fleet-monitor.py (origin/v3 @ 1e98ab5)
#

# --- END HEADER ---

import argparse
import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime
from pathlib import Path

import yaml

from rich import box
from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


# Runtime fleet.yaml — single source of truth, no fallback
_FLEET_YAML_PATH = Path("/local/LCARS/fleet/fleet.yaml")


def _load_fleet_user() -> str:
    # F-D1 FIX: Path.exists() can raise PermissionError — wrap entire block
    try:
        if not _FLEET_YAML_PATH.exists():
            return ""
        with _FLEET_YAML_PATH.open(encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
            return data.get("fleet", {}).get("identity", {}).get("fleet_user", "")
    except Exception:
        return ""


FLEET_USER: str = _load_fleet_user()

HUB_DEFAULT = "http://127.0.0.1:8765"
REFRESH_INTERVAL = 2

STATUS_STYLE = {
    # v7 #02: phase values (primary) + legacy compat
    "idle":        ("#88AAFF", "●"),   # bleu-gris  — nominal
    "active":      ("#FF9900", "◉"),   # orange     — actif
    "startup":     ("#FFCC00", "⟳"),   # ambre      — init
    "waiting":     ("#FFCC99", "◐"),   # pêche      — attente
    "handoff":     ("#88AAFF", "↗"),   # bleu       — handoff
    "shutdown":    ("dim",     "↓"),   # dim        — arrêt
    "offline":     ("dim",     "—"),
    # legacy compat (pre-v7 handoffs)
    "done":        ("#88AAFF", "●"),
    "pending":     ("#FFCC99", "◐"),
    "in-progress": ("#FF9900", "◉"),
    "blocked":     ("#FF4444", "✖"),
    # errors
    "absent":      ("dim",     "○"),
    "unknown":     ("dim",     "?"),
    "error":       ("#FF4444", "✖"),
}

ALERT_SCRIPT = Path(__file__).parent / "fleet-alert.sh"
WAKE_SCRIPT = Path(__file__).parent / "wake-instance.sh"
FLEET_STATE_SCRIPT = Path(__file__).parent / "fleet-state.sh"
NOTIFIED_CACHE = Path(os.environ.get("FLEET_STATE_DIR", "/home/fleet-state") + "/run/fleet-monitor-notified.json")
SPOOL_COUNTS_CACHE = Path(os.environ.get("FLEET_STATE_DIR", "/home/fleet-state") + "/run/fleet-monitor-spool-counts.json")
NOTIFIED_MAX_AGE = 600  # 10 min — invalide après reboot

# v7 #02 Phase 4: dynamic — populated from hub /state response at runtime
INSTANCE_NAMES: set[str] = set()


def fetch_json(url: str, timeout: int = 2) -> tuple[dict, str | None]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read()), None
    except Exception as e:
        return {}, str(e)


def age_label(date_str: str) -> str:
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d %H:%M")
        delta = datetime.now() - dt
        total_secs = delta.total_seconds()
        future = total_secs < 0
        mins = int(abs(total_secs) // 60)
        if mins < 60:
            label = f"{mins}m"
        elif mins < 1440:
            hours = mins // 60
            label = f"{hours}h{mins % 60:02d}m"
        else:
            label = f"{mins // 1440}j"
        return ("+" if future else "") + label
    except ValueError:
        return "?"


def make_instance_panel(instance_id: str, data: dict, spool_count: int = 0) -> Panel:
    # v7 #02: action= is now phase, status= is now activity
    phase    = data.get("action", "unknown")
    activity = data.get("status", "unknown")
    notify   = data.get("notify", "none")

    # notify → instance : override phase pour refléter la coordination
    if notify and notify not in ("none", "") and notify in INSTANCE_NAMES:
        phase = "active"

    stale   = data.get("stale", True)
    style, dot = STATUS_STYLE.get(phase, STATUS_STYLE.get(activity, ("dim", "?")))

    crashed = stale and phase == "active"
    if crashed:
        style = "#FF4444"
        dot   = "!"
    elif stale and phase not in ("absent", "unknown", "error", "offline", "shutdown"):
        style = "dim"
        dot   = "~"

    content = Table.grid(padding=(0, 1))
    content.add_column(style="dim", width=8)
    content.add_column()

    # Ligne phase + activity
    display = f"{phase}:{activity}" if activity not in ("—", "unknown", "done") else phase
    content.add_row("state", Text(f"{dot} {display}", style=f"{style} bold"))

    # Ligne verbose — premier action en attente
    pending = data.get("pending_actions", [])
    if pending:
        content.add_row("", Text(pending[0], style="white" if not stale else "dim"))

    # ref + date sur une ligne
    date_str = data.get("date", "")
    age      = age_label(date_str) if date_str else "?"
    ref_line = Text()
    ref_line.append(data.get("ref", "-"), style="#88AAFF")
    if date_str:
        ref_line.append(f"  {date_str}", style="dim" if stale else "white")
        ref_line.append(f"  ({age})", style="dim")
    if crashed:
        ref_line.append("  [CRASH?]", style="#FF4444 bold")
    elif stale:
        ref_line.append("  [STALE]", style="dim")
    content.add_row("ref", ref_line)

    # Actions en attente — après date, avant blocker
    for act in pending:
        content.add_row("[ ]", Text(act, style="yellow"))

    # Blocker
    blocker = data.get("blocker", "none")
    if blocker and blocker not in ("none", ""):
        content.add_row("blocker", Text(blocker, style="red"))

    # Waiting / Notify (herald)
    waiting = data.get("waiting", "none")
    if waiting and waiting not in ("none", ""):
        content.add_row("waiting", Text(f"⏳ {waiting}", style="magenta"))
    notify_val = data.get("notify", "none")
    if notify_val and notify_val not in ("none", ""):
        content.add_row("notify", Text(f"⚡ {notify_val}", style="magenta bold"))

    # Spool inbox count
    if spool_count > 0:
        content.add_row("inbox", Text(f"📬 {spool_count}", style="#FFCC00 bold"))

    if "error" in data and phase == "error":
        content.add_row("err", Text(data["error"][:60], style="red dim"))

    border_style = style if not stale else ("#FF4444" if crashed else "dim")
    return Panel(content, title=f"[bold]{instance_id}[/bold]",
                 border_style=border_style, box=box.HEAVY, padding=(0, 1))


def build_layout(states: dict, spool_counts: dict, hub_error: str | None, last_refresh: str) -> Layout:
    layout = Layout()
    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="instances"),
    )

    # Header
    hub_status = Text()
    if hub_error:
        hub_status.append(f"  hub UNREACHABLE — {hub_error[:60]}", style="red bold")
    else:
        hub_status.append("  fleet-hub ", style="dim")
        hub_status.append("●", style="#88AAFF")
        hub_status.append(f"  refreshed {last_refresh}", style="dim")
    layout["header"].update(
        Panel(hub_status, title="[bold #FF9900]fleet monitor v5[/bold #FF9900]",
              border_style="#CC88FF", box=box.HEAVY, padding=(0, 1))
    )

    # v7 #02 Phase 4: dynamic grid from hub /state (not hardcoded roles)
    instance_ids = sorted(states.keys()) if states else ["starfleet"]
    cards = {
        iid: make_instance_panel(
            iid,
            states.get(iid, {"status": "absent", "stale": True}),
            spool_counts.get(iid, 0),
        )
        for iid in instance_ids
    }
    # Split into rows of 3
    rows = [instance_ids[i:i+3] for i in range(0, len(instance_ids), 3)]
    instances = Layout()
    row_layouts = [Layout(name=f"row_{i}") for i in range(len(rows))]
    instances.split_column(*row_layouts)
    for i, row in enumerate(rows):
        col_layouts = [Layout(name=iid) for iid in row]
        row_layouts[i].split_row(*col_layouts)
        for iid in row:
            instances[iid].update(cards[iid])
    layout["instances"].update(instances)

    return layout


def fire_gyrophare(instance: str):
    """Start visual alert (gyrophare) for user attention."""
    if ALERT_SCRIPT.exists():
        subprocess.Popen(
            [str(ALERT_SCRIPT), instance],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def reset_notify(instance: str):
    """Reset notify field via fleet-state.sh notify=none."""
    if FLEET_STATE_SCRIPT.exists():
        subprocess.Popen(
            [str(FLEET_STATE_SCRIPT), instance, "notify=none"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def load_notified() -> dict[str, str]:
    try:
        if NOTIFIED_CACHE.exists():
            age = time.time() - NOTIFIED_CACHE.stat().st_mtime
            if age < NOTIFIED_MAX_AGE:
                return json.loads(NOTIFIED_CACHE.read_text())
    except OSError:
        pass
    return {}


def save_notified(notified: dict[str, str]) -> None:
    try:
        tmp = NOTIFIED_CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(notified))
        tmp.rename(NOTIFIED_CACHE)
    except OSError:
        pass


def load_spool_counts() -> dict[str, int]:
    try:
        if SPOOL_COUNTS_CACHE.exists():
            age = time.time() - SPOOL_COUNTS_CACHE.stat().st_mtime
            if age < NOTIFIED_MAX_AGE:
                return json.loads(SPOOL_COUNTS_CACHE.read_text())
    except OSError:
        pass
    return {}


def save_spool_counts(counts: dict[str, int]) -> None:
    try:
        tmp = SPOOL_COUNTS_CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(counts))
        tmp.rename(SPOOL_COUNTS_CACHE)
    except OSError:
        pass


def dispatch_notify(instance: str, waiting: str, notify: str):
    # v7 #05: herald removed, replaced by gyrophare. Wake removed — inotify daemon handles it.
    if notify == FLEET_USER:
        fire_gyrophare(instance)
    # Agent wake is handled by inbox-watch-daemon (inotifywait), not monitor.


DISPATCH_COOLDOWN = 15  # seconds — prevents double-wake on hub stale cache


def run(hub_url: str, interval: int):
    console = Console()
    notified: dict[str, str] = load_notified()
    cooldown: dict[str, float] = {}
    spool_counts_prev: dict[str, int] = load_spool_counts()

    with Live(console=console, refresh_per_second=1, screen=True) as live:
        while True:
            states, hub_err = fetch_json(f"{hub_url}/state")
            spool_counts, _ = fetch_json(f"{hub_url}/spool")
            last_refresh = datetime.now().strftime("%H:%M:%S")

            # v7 #02 Phase 4: dynamic instance names from hub
            global INSTANCE_NAMES
            if states:
                INSTANCE_NAMES = set(states.keys())

            # Dispatch notify (herald ou wake)
            for iid, data in states.items():
                notify_val = data.get("notify", "none")
                waiting_val = data.get("waiting", "none")
                if notify_val not in ("none", ""):
                    if notified.get(iid) != notify_val:
                        if time.time() - cooldown.get(iid, 0) >= DISPATCH_COOLDOWN:
                            dispatch_notify(iid, waiting_val, notify_val)
                            notified[iid] = notify_val
                            cooldown[iid] = time.time()
                            save_notified(notified)
                            reset_notify(iid)
                else:
                    if notified.pop(iid, None) is not None:
                        save_notified(notified)

            # M5-FIX: spool wake removed — fleet-send.sh handles wake on delivery.
            # Monitor observes, it does not act.

            layout = build_layout(states, spool_counts, hub_err, last_refresh)
            live.update(layout)

            time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="fleet-monitor v5 — dashboard Rich pour la flotte")
    parser.add_argument("--hub", default=HUB_DEFAULT)
    parser.add_argument("--interval", type=int, default=REFRESH_INTERVAL)
    args = parser.parse_args()

    try:
        run(args.hub, args.interval)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
