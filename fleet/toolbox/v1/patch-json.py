#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: patch-json.py
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET v6.0
#     |  |  v6.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: PATCH-JSON      | SUBSYSTEM: TOOLBOX / DEPLOY     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.090              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  JSON settings patcher for deploy.sh.                     |
#     |  Hook registration + field updates. Idempotent.           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     patch-json.py — JSON settings patcher for deploy.sh.
#
#     [EN]
#     patch-json.py — JSON settings patcher for deploy.sh.
#     Hook registration + field updates. Idempotent.
#
#
# --- END HEADER ---

import json
import sys


def register_hook(path, hook_key, matcher, cmd):
    with open(path) as f:
        s = json.load(f)

    hooks = s.setdefault("hooks", {})
    hook_list = hooks.setdefault(hook_key, [])

    # Check if already registered
    already = any(
        any(h.get("command") == cmd for h in entry.get("hooks", []))
        for entry in hook_list
    )

    if already:
        print(f"  [ok] {path} — {hook_key} already registered")
        return

    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher:
        entry["matcher"] = matcher

    hook_list.append(entry)

    # JUPITER-017: atomic write via temp+rename
    import tempfile, os
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

    print(f"  [patché] {path} — {hook_key}")


def set_field(path, field, value):
    with open(path) as f:
        s = json.load(f)

    if s.get(field) == value:
        label = path.split("/")[-3] if "/" in path else path
        print(f"  {label}: already {value}")
        return

    s[field] = value

    # JUPITER-017: atomic write
    import tempfile, os
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)

    label = path.split("/")[-3] if "/" in path else path
    print(f"  {label}: set to {value}")


def reset_hooks(path):
    """Remove all hooks — called before re-registering from hooks.yaml (convergent deploy)."""
    import os, tempfile
    with open(path) as f:
        s = json.load(f)
    s["hooks"] = {}
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    print(f"  [reset] {path} — hooks cleared")


def main():
    if len(sys.argv) < 2:
        print("usage: patch-json.py <register-hook|reset-hooks|set-field> ...", file=sys.stderr)
        sys.exit(1)

    action = sys.argv[1]

    if action == "reset-hooks":
        if len(sys.argv) != 3:
            print("usage: patch-json.py reset-hooks <file>", file=sys.stderr)
            sys.exit(1)
        reset_hooks(sys.argv[2])

    elif action == "register-hook":
        if len(sys.argv) != 6:
            print("usage: patch-json.py register-hook <file> <hook_key> <matcher> <command>", file=sys.stderr)
            sys.exit(1)
        register_hook(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])

    elif action == "set-field":
        if len(sys.argv) != 5:
            print("usage: patch-json.py set-field <file> <field> <value>", file=sys.stderr)
            sys.exit(1)
        set_field(sys.argv[2], sys.argv[3], sys.argv[4])

    else:
        print(f"unknown action: {action}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
