#!/usr/bin/env python3
# SOURCE: lcars-header.py
# AUTHOR: starfleet
# STARDATE: 2026-03-26 | STATUS: active | MODULE: toolbox | SUBSYSTEM: fleet
"""
LCARS Fleet — Header generator

Generates standardized LCARS headers for shell scripts.
Single template, consistent output, no more drift.

Usage:
    lcars-header.py --source NAME --module MOD --subsystem SUB \
                    --desc-en "..." --desc-fr "..." \
                    [--author NAME] [--deploy TAG] [--shebang LINE] \
                    [--synopsis "..."]

    lcars-header.py --from-file script.sh   # extract metadata, regenerate header

    lcars-header.py --batch manifest.yaml   # regenerate all headers from manifest
"""

import argparse
import datetime
import sys
import re
import yaml
from pathlib import Path

# --- Constants ---
VERSION = "6.0"
YEAR = "2026"
LICENSE = "AGPL-3"


def day_of_year():
    """STARDATE = YYYY.DDD (day of year, zero-padded)."""
    return datetime.date.today().strftime("%Y.%j").lstrip("0").replace(".0", ".")


def format_field(label, value, width=42):
    """Format a right-padded field for the ASCII art box."""
    content = f"{label}: {value}"
    return content.ljust(width)


def wrap_desc(text, width=55, prefix="#     |  "):
    """Wrap description lines to fit inside the box."""
    words = text.split()
    lines = []
    current = ""
    for word in words:
        if len(current) + len(word) + 1 > width:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}" if current else word
    if current:
        lines.append(current)
    return lines


def generate_header(
    source,
    module,
    subsystem,
    desc_en,
    desc_fr,
    author="STARFLEET",
    deploy=None,
    shebang="#!/bin/bash",
    stardate=None,
    synopsis=None,
):
    """Generate a complete LCARS header."""
    if stardate is None:
        stardate = day_of_year()

    lines = []

    # Shebang
    lines.append(shebang)

    # Deploy tag
    if deploy:
        lines.append(f"# DEPLOY: {deploy}")

    lines.append("")

    # ASCII art header
    lines.append("#       ______________________________________________________")
    lines.append("#      /          LCARS FLEET - FEDERATION DATABASE           \\")
    lines.append("#     |   ________   __________________________________________\\")
    lines.append(f"#     |  |  {YEAR}  |  | SOURCE: {source}")
    lines.append(f"#     |  |________|  | AUTHOR: {author}")
    lines.append(f"#     |   ________   | SYSTEM: LCARS-FLEET v{VERSION}")
    lines.append(f"#     |  |  v{VERSION}  |  | STATUS: OPERATIONAL")
    lines.append("#     |  |________|  |__________________________________________")
    lines.append("#     |              \\__________________________________________\\")
    lines.append('#      \\    "To boldly go where no code has gone before..."     /')
    lines.append("#       \\______________________________________________________/")
    lines.append("#")

    # Info box — total width = 61 chars between outer +/+
    # Layout: | left-col (25 chars incl pipes) | right-col (35 chars incl pipe) |
    BOX_W = 61
    LEFT_W = 26  # "| MODULE: FLEET-ALERT     " = 26 chars (no trailing pipe)
    RIGHT_W = BOX_W - LEFT_W  # 35

    def box_row(left_label, left_val, right_label, right_val):
        left = f"| {left_label}: {left_val}"
        left = left.ljust(LEFT_W)
        right = f"| {right_label}: {right_val}"
        right = right.ljust(RIGHT_W - 1) + "|"
        return left + right

    top_sep = f"+{'-' * (BOX_W - 2)}+"
    mid_sep = f"+{'-' * (LEFT_W - 1)}+{'-' * (RIGHT_W - 2)}+"

    lines.append(f"#     {top_sep}")
    lines.append(f"#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |")
    lines.append(f"#     {top_sep}")
    lines.append(f"#     {box_row('MODULE', module, 'SUBSYSTEM', subsystem)}")
    lines.append(f"#     {box_row('LICENSE', LICENSE, 'STARDATE', stardate)}")
    lines.append(f"#     {mid_sep}")

    # Description box (EN, inside the box)
    desc_lines = wrap_desc(desc_en)
    empty_row = f"|{' ' * (BOX_W - 2)}|"
    lines.append(f"#     {empty_row}")
    for dl in desc_lines:
        padded = dl.ljust(BOX_W - 4)
        lines.append(f"#     |  {padded}|")
    lines.append(f"#     {empty_row}")
    lines.append(f"#     {top_sep}")

    # [FR] section — description only, NO ASCII art
    lines.append("#")
    lines.append("#     [FR]")
    for fr_line in desc_fr.split("\n"):
        lines.append(f"#     {fr_line.strip()}")

    # [EN] section
    lines.append("#")
    lines.append("#     [EN]")
    if synopsis:
        lines.append(f"#     NAME")
        lines.append(f"#         {source} — {desc_en.split('.')[0]}")
        lines.append(f"#")
        lines.append(f"#     SYNOPSIS")
        for syn_line in synopsis.split("\n"):
            lines.append(f"#         {syn_line.strip()}")
    else:
        lines.append(f"#     {source} — {desc_en}")
    lines.append("#")
    lines.append("#")
    lines.append("# --- END HEADER ---")

    return "\n".join(lines)


def generate_banner(
    title,
    status="BOOT",
    status_color="G",
    version=VERSION,
    info_lines=None,
    quote=True,
):
    """Generate a colored LCARS banner for terminal display.

    Args:
        title: Main title (e.g. "POST-REBOOT BOOTSTRAP")
        status: Status badge text (e.g. "BOOT", "AUTH", "DONE")
        status_color: Color key: G=green, Y=yellow, R=red, W=white
        version: Version string for the badge
        info_lines: List of "label : value" strings for the info area
        quote: Include the "To boldly go..." quote line
    """
    # ANSI color codes (real escape bytes for terminal, \033 literals for echo -e)
    AMBER = "\x1b[38;5;214m"
    G = "\x1b[1;32m"
    Y = "\x1b[1;33m"
    R = "\x1b[1;31m"
    W = "\x1b[1;37m"
    D = "\x1b[2m"
    N = "\x1b[0m"

    colors = {"G": G, "Y": Y, "R": R, "W": W}
    sc = colors.get(status_color, G)

    if info_lines is None:
        info_lines = []

    lines = []
    lines.append(f'{AMBER}       ______________________________________________________')
    lines.append(f'      /          LCARS FLEET - FEDERATION DATABASE           \\')
    lines.append(f'     |   ________   __________________________________________\\')
    lines.append(f'     |  |  {YEAR}  |  |{W} {title}{AMBER}')
    lines.append(f'     |  |________|  |{N}{AMBER}')
    lines.append(f'     |   ________   |{N}{AMBER}')
    lines.append(f'     |  | {sc}{status.ljust(4)}{AMBER}  |  |{N}{AMBER}')
    lines.append(f'     |  |________|  |{N}{AMBER}')

    # Info lines (right side of the art)
    for info in info_lines:
        lines.append(f'     |              |{N} {info}{AMBER}')

    if not info_lines:
        lines.append(f'     |              |{N}{AMBER}')

    if quote:
        lines.append(f'      \\    {N}{D}"To boldly go where no code has gone before..."{N}{AMBER}     /')
    lines.append(f'       \\______________________________________________________/{N}')

    # Return raw lines (real ANSI escapes embedded)
    return "\n".join(lines)


def extract_metadata(filepath):
    """Extract metadata from an existing LCARS header."""
    meta = {}
    content = Path(filepath).read_text()
    header_match = re.search(r"^(.*?# --- END HEADER ---)", content, re.DOTALL)
    if not header_match:
        return None, content

    header = header_match.group(1)
    body = content[header_match.end():]

    # Extract fields
    m = re.search(r"SOURCE:\s*(.+)", header)
    if m: meta["source"] = m.group(1).strip()

    m = re.search(r"AUTHOR:\s*(.+)", header)
    if m: meta["author"] = m.group(1).strip()

    m = re.search(r"MODULE:\s*([^|]+)", header)
    if m: meta["module"] = m.group(1).strip()

    m = re.search(r"SUBSYSTEM:\s*([^|]+)", header)
    if m: meta["subsystem"] = m.group(1).strip()

    m = re.search(r"STARDATE:\s*([^|]+)", header)
    if m: meta["stardate"] = m.group(1).strip()

    m = re.search(r"DEPLOY:\s*(.+)", header)
    if m: meta["deploy"] = m.group(1).strip()

    # Shebang
    first_line = content.split("\n")[0]
    if first_line.startswith("#!"):
        meta["shebang"] = first_line

    # [FR] description
    fr_match = re.search(r"\[FR\]\n(.*?)(?=\n#\s*\[EN\])", header, re.DOTALL)
    if fr_match:
        fr_lines = [l.lstrip("#").strip() for l in fr_match.group(1).strip().split("\n")]
        # Filter out ASCII art duplicates
        fr_lines = [l for l in fr_lines if not re.match(r"[_/\\|+\-\[\]]", l.lstrip()) and l]
        meta["desc_fr"] = "\n".join(fr_lines)

    # [EN] description (first meaningful line)
    en_match = re.search(r"\[EN\]\n(.*?)(?=\n#\s*\n#\s*# ---)", header, re.DOTALL)
    if en_match:
        en_lines = [l.lstrip("#").strip() for l in en_match.group(1).strip().split("\n")]
        en_lines = [l for l in en_lines if l]
        if en_lines:
            # If NAME/SYNOPSIS format, extract description
            desc_line = en_lines[0]
            if desc_line.startswith("NAME"):
                desc_line = en_lines[1] if len(en_lines) > 1 else ""
            # Strip "filename — " prefix
            desc_line = re.sub(r"^\S+\s*—\s*", "", desc_line)
            meta["desc_en"] = desc_line

    # Description from box
    box_match = re.findall(r"#\s+\|\s{2}(.+?)\s*\|", header)
    if box_match and "desc_en" not in meta:
        desc_parts = [l.strip() for l in box_match if l.strip()]
        meta["desc_en"] = " ".join(desc_parts)

    return meta, body


def process_file(filepath, dry_run=False):
    """Regenerate header for a single file."""
    meta, body = extract_metadata(filepath)
    if meta is None:
        print(f"  SKIP {filepath} — no END HEADER marker", file=sys.stderr)
        return False

    required = ["source", "module", "subsystem"]
    missing = [k for k in required if k not in meta]
    if missing:
        print(f"  FAIL {filepath} — missing: {', '.join(missing)}", file=sys.stderr)
        return False

    new_header = generate_header(
        source=meta["source"],
        module=meta["module"],
        subsystem=meta["subsystem"],
        desc_en=meta.get("desc_en", ""),
        desc_fr=meta.get("desc_fr", ""),
        author=meta.get("author", "STARFLEET"),
        deploy=meta.get("deploy"),
        shebang=meta.get("shebang", "#!/bin/bash"),
        stardate=meta.get("stardate"),
    )

    new_content = new_header + body

    if dry_run:
        print(f"  DRY {filepath}")
        return True

    Path(filepath).write_text(new_content)
    print(f"  OK  {filepath}")
    return True


def batch_process(manifest_path, dry_run=False):
    """Process all files from a YAML manifest."""
    manifest = yaml.safe_load(Path(manifest_path).read_text())
    ok = fail = skip = 0
    for entry in manifest.get("files", []):
        filepath = entry.get("path")
        if not filepath or not Path(filepath).exists():
            print(f"  SKIP {filepath} — not found", file=sys.stderr)
            skip += 1
            continue
        if process_file(filepath, dry_run):
            ok += 1
        else:
            fail += 1
    print(f"\n{ok} OK, {fail} FAIL, {skip} SKIP")


def main():
    parser = argparse.ArgumentParser(description="LCARS header generator")
    sub = parser.add_subparsers(dest="command")

    # generate
    gen = sub.add_parser("generate", help="Generate a header from parameters")
    gen.add_argument("--source", required=True)
    gen.add_argument("--module", required=True)
    gen.add_argument("--subsystem", required=True)
    gen.add_argument("--desc-en", required=True)
    gen.add_argument("--desc-fr", required=True)
    gen.add_argument("--author", default="STARFLEET")
    gen.add_argument("--deploy", default=None)
    gen.add_argument("--shebang", default="#!/bin/bash")
    gen.add_argument("--stardate", default=None)
    gen.add_argument("--synopsis", default=None)

    # regen
    regen = sub.add_parser("regen", help="Regenerate header from existing file")
    regen.add_argument("file")
    regen.add_argument("--dry-run", action="store_true")

    # banner
    ban = sub.add_parser("banner", help="Generate a colored terminal banner")
    ban.add_argument("--title", required=True, help="Main title text")
    ban.add_argument("--status", default="BOOT", help="Status badge (BOOT/AUTH/DONE/etc)")
    ban.add_argument("--status-color", default="G", help="Badge color: G/Y/R/W")
    ban.add_argument("--version", default=VERSION)
    ban.add_argument("--info", nargs="*", default=[], help="Info lines (label : value)")
    ban.add_argument("--no-quote", action="store_true", help="Omit the quote line")
    ban.add_argument("--raw", action="store_true", help="Output raw text (no echo wrapper)")

    # batch
    batch = sub.add_parser("batch", help="Regenerate headers from manifest")
    batch.add_argument("manifest")
    batch.add_argument("--dry-run", action="store_true")

    args = parser.parse_args()

    if args.command == "generate":
        print(generate_header(
            source=args.source,
            module=args.module,
            subsystem=args.subsystem,
            desc_en=args.desc_en,
            desc_fr=args.desc_fr,
            author=args.author,
            deploy=args.deploy,
            shebang=args.shebang,
            stardate=args.stardate,
            synopsis=args.synopsis,
        ))
    elif args.command == "banner":
        output = generate_banner(
            title=args.title,
            status=args.status,
            status_color=args.status_color,
            version=args.version,
            info_lines=args.info,
            quote=not args.no_quote,
        )
        print(output)
    elif args.command == "regen":
        process_file(args.file, args.dry_run)
    elif args.command == "batch":
        batch_process(args.manifest, args.dry_run)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
