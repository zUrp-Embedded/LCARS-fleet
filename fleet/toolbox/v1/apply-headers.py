#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: apply-headers.py
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
#     | MODULE: APPLY-HEADERS   | SUBSYSTEM: TOOLBOX / MAINT      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Idempotent — skips files already up-to-date.             |
#     |                                                           |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     apply-headers.py — Idempotent — skips files already up-to-date.
#
#     [EN]
#     apply-headers.py — Idempotent — skips files already up-to-date.
#
#
# --- END HEADER ---

import datetime
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: pyyaml required — pip install pyyaml", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
NEW_MARKER = "|  2026  |"
END_HEADER_MARKER = "# --- END HEADER ---"
STARDATE = datetime.datetime.now().strftime('%Y.%j')

# Load metadata from external YAML (single source of truth for header definitions)
METADATA_YAML = Path(__file__).resolve().parent / "header-metadata.yaml"
if not METADATA_YAML.exists():
    print(f"ERROR: {METADATA_YAML} not found", file=sys.stderr)
    sys.exit(1)
with open(METADATA_YAML) as _f:
    _raw = yaml.safe_load(_f)
METADATA = _raw.get("files", {})




def strip_old_header(lines, is_python, start=1):
    """
    Returns (old_header_text, body_start_idx).
    Strips all leading comment/blank lines after shebang.
    For Python: strips triple-quote docstring too.
    start=0 for files without shebang (yaml, conf).
    """
    i = start
    old_header_lines = []

    if is_python:
        # Skip blank lines
        while i < len(lines) and lines[i].strip() == "":
            i += 1
        # Strip triple-quote docstring if present
        if i < len(lines) and lines[i].strip().startswith('"""'):
            docstring_lines = []
            first = lines[i].rstrip()
            docstring_lines.append(first)
            # Check if it closes on same line (single-line docstring)
            rest = first.strip()[3:]
            if rest.endswith('"""') and len(rest) > 0:
                i += 1
            else:
                i += 1
                while i < len(lines) and '"""' not in lines[i]:
                    docstring_lines.append(lines[i].rstrip())
                    i += 1
                if i < len(lines):
                    docstring_lines.append(lines[i].rstrip())
                    i += 1
            old_header_lines = docstring_lines
        # Skip any remaining blank/#-comment lines after docstring
        while i < len(lines) and (
            lines[i].strip() == "" or lines[i].strip().startswith("#")
        ):
            i += 1
    else:
        # Strip contiguous # and blank lines (stop at END HEADER marker)
        while i < len(lines) and (
            lines[i].strip() == "" or lines[i].strip().startswith("#")
        ):
            if END_HEADER_MARKER in lines[i]:
                i += 1  # skip the marker itself
                break
            old_header_lines.append(lines[i].rstrip())
            i += 1

    return old_header_lines, i


def extract_fr_lines(old_header_lines, is_python):
    """Extract description text from old header for the [FR] section."""
    raw = []

    if is_python:
        # Strip """ markers, collect content
        for line in old_header_lines:
            s = line.rstrip()
            if s.strip() in ('"""',):
                continue
            raw.append(s)
    else:
        for line in old_header_lines:
            # Remove leading #, optional single space
            content = re.sub(r"^#+ ?", "", line.rstrip())
            # Skip pure separator lines
            if re.match(r"^[\s=\-─═*]+$", content) or content.strip() == "":
                if not raw:
                    continue  # skip leading blanks
                raw.append("")
                continue
            raw.append(content)

    # Trim leading/trailing blanks
    while raw and raw[0].strip() == "":
        raw.pop(0)
    while raw and raw[-1].strip() == "":
        raw.pop()

    # Limit to reasonable length (first 6 non-empty lines)
    result = []
    for line in raw:
        result.append(line)
        if len([x for x in result if x.strip()]) >= 6:
            break

    return result


def build_header(filename, meta, old_fr_lines):
    module = meta["module"]
    subsystem = meta["subsystem"]
    desc1 = meta["desc1"]
    desc2 = meta["desc2"]

    c = "#"

    art = [
        f"{c}       ______________________________________________________",
        f"{c}      /          LCARS FLEET - FEDERATION DATABASE           \\",
        f"{c}     |   ________   __________________________________________\\",
        f"{c}     |  |  2026  |  | SOURCE: {filename}",
        f"{c}     |  |________|  | AUTHOR: STARFLEET",
        f"{c}     |   ________   | SYSTEM: LCARS-FLEET v6.0",
        f"{c}     |  |  v6.0  |  | STATUS: OPERATIONAL",
        f"{c}     |  |________|  |__________________________________________",
        f"{c}     |              \\__________________________________________\\",
        f'{c}      \\    "To boldly go where no code has gone before..."     /',
        f"{c}       \\______________________________________________________/",
    ]

    box = [
        f"{c}",
        f"{c}     +-----------------------------------------------------------+",
        f"{c}     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |",
        f"{c}     +-----------------------------------------------------------+",
        f"{c}     | MODULE: {module:<16}| SUBSYSTEM: {subsystem:<21}|",
        f"{c}     | LICENSE: AGPL-3         | STARDATE: {STARDATE:<22}|",
        f"{c}     +-------------------------+---------------------------------+",
        f"{c}     |                                                           |",
        f"{c}     |  {desc1:<57}|",
        f"{c}     |  {desc2:<57}|",
        f"{c}     |                                                           |",
        f"{c}     +-----------------------------------------------------------+",
    ]

    fr_section = [f"{c}"]
    fr_section.append(f"{c}     [FR]")
    if old_fr_lines:
        for line in old_fr_lines:
            fr_section.append(f"{c}     {line}" if line.strip() else f"{c}")
    else:
        fr_section.append(f"{c}     {filename} — {desc1}")

    en_section = [f"{c}"]
    en_section.append(f"{c}     [EN]")
    en_section.append(f"{c}     {filename} — {desc1}")
    if desc2:
        en_section.append(f"{c}     {desc2}")
    en_section.append(f"{c}")

    end_marker = [f"{c}", END_HEADER_MARKER]
    return "\n".join(art + box + fr_section + en_section + end_marker)


def process_file(filepath):
    rel = str(filepath.relative_to(REPO_ROOT))

    # Check if file is in METADATA
    if rel not in METADATA:
        print(f"  SKIP (no metadata): {rel}")
        return False

    meta = METADATA[rel]
    if meta is None:
        # Explicitly excluded
        print(f"  SKIP (excluded):    {rel}")
        return False

    # Check for new marker
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        head = [next(f, "") for _ in range(50)]
    has_art = any(NEW_MARKER in line for line in head)
    has_end = any(END_HEADER_MARKER in line for line in head)
    if has_art and has_end:
        print(f"  SKIP (up-to-date):  {rel}")
        return False

    # Read full file
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    lines = content.splitlines()
    if not lines:
        print(f"  SKIP (empty):       {rel}")
        return False

    has_shebang = lines[0].startswith("#!")
    shebang = lines[0] if has_shebang else ""
    is_python = filepath.suffix == ".py"

    # Preserve pragmas between shebang and header (e.g. # DEPLOY: instance-util)
    pragmas = []
    pragma_start = 1 if has_shebang else 0
    for j in range(pragma_start, min(pragma_start + 5, len(lines))):
        stripped = lines[j].strip()
        if stripped.startswith("# DEPLOY:"):
            pragmas.append(lines[j].rstrip())
        elif stripped == "" or stripped.startswith("#"):
            continue  # skip blanks and other comments before header art
        else:
            break

    old_header_lines, body_start = strip_old_header(lines, is_python, start=1 if has_shebang else 0)
    old_fr = extract_fr_lines(old_header_lines, is_python)

    filename = filepath.name
    header = build_header(filename, meta, old_fr)

    body = "\n".join(lines[body_start:])

    pragma_block = "\n".join(pragmas)
    if has_shebang:
        if pragma_block:
            new_content = shebang + "\n" + pragma_block + "\n" + "\n" + header + "\n" + "\n" + body + "\n"
        else:
            new_content = shebang + "\n" + "\n" + header + "\n" + "\n" + body + "\n"
    else:
        new_content = header + "\n" + "\n" + body + "\n"

    orig_mode = filepath.stat().st_mode
    tmp = filepath.with_suffix(filepath.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_content)
    os.chmod(tmp, orig_mode)
    tmp.rename(filepath)

    print(f"  updated:            {rel}")
    return True


def main():
    dry_run = "--dry-run" in sys.argv

    files = sorted(
        f
        for f in REPO_ROOT.rglob("*")
        if f.is_file()
        and f.suffix in (".sh", ".py", ".yaml", ".yml", ".conf")
        and ".git" not in f.parts
        and "_archived" not in f.parts
        and "docs" not in f.parts
        and "settings" not in f.name
        and f.name != "exemple.sh"
    )

    updated = 0
    skipped = 0

    for filepath in files:
        rel = str(filepath.relative_to(REPO_ROOT))
        meta = METADATA.get(rel)

        if dry_run:
            if meta is None and rel in METADATA:
                print(f"  SKIP (excluded):    {rel}")
            elif meta is None:
                print(f"  SKIP (no metadata): {rel}")
            else:
                with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                    head = [next(f, "") for _ in range(50)]
                has_art = any(NEW_MARKER in line for line in head)
                has_end = any(END_HEADER_MARKER in line for line in head)
                if has_art and has_end:
                    print(f"  SKIP (up-to-date):  {rel}")
                else:
                    print(f"  WOULD UPDATE:       {rel}")
            continue

        result = process_file(filepath)
        if result:
            updated += 1
        else:
            skipped += 1

    if not dry_run:
        print(f"\n→ {updated} file(s) updated, {skipped} skipped  [ stardate: {STARDATE} ]")


if __name__ == "__main__":
    main()
