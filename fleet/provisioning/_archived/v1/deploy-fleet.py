#!/usr/bin/env python3

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: deploy-fleet.py
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: FLEET-DEPLOY    | SUBSYSTEM: FLEET / INSTALL      |
#     | LICENSE: AGPL-3         | STARDATE: 2026.063              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Deploys fleet configuration to instance homes.           |
#     |  Generates per-instance CLAUDE.md from templates.         |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     deploy-fleet.py — génère un script PowerShell de déploiement depuis fleet.yaml
#
#     Tourne sur starfleet (Python 3.12, wsl.exe inaccessible depuis WSL).
#     Lit fleet.yaml, génère deploy-fleet.ps1 à exécuter depuis Windows Terminal.
#
#     Usage :
#         python3 deploy-fleet.py [--output deploy-fleet.ps1] [--instance <id>]
#         python3 deploy-fleet.py --list
#
#     [EN]
#     deploy-fleet.py — Deploys fleet configuration to instance homes.
#     Generates per-instance CLAUDE.md from templates.
#

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Erreur : pyyaml requis. Installer avec : pip install pyyaml", file=sys.stderr)
    sys.exit(1)


FLEET_YAML = Path(__file__).parent / "fleet.yaml"


def load_fleet(path: Path) -> dict:
    with open(path) as f:
        data = yaml.safe_load(f)
    return data


def validate_fleet(data: dict) -> list[str]:
    errors = []
    if "fleet" not in data:
        errors.append("Clé 'fleet' manquante")
    if "instances" not in data:
        errors.append("Clé 'instances' manquante")
        return errors
    required_fields = {"id", "wsl-name", "instance-type", "user"}
    for inst in data["instances"]:
        missing = required_fields - inst.keys()
        if missing:
            errors.append(f"Instance '{inst.get('id', '?')}' : champs manquants {missing}")
    return errors


def generate_ps1(data: dict, instances: list[dict]) -> str:
    fleet = data["fleet"]
    sources_subdir = fleet['sources_dir']

    lines = [
        "# deploy-fleet.ps1 - genere par deploy-fleet.py",
        "# Executer depuis Windows Terminal (PowerShell, pas WSL)",
        "# Placer ce fichier dans provisioning\\wsl2\\ (aux cotes de Instanciator.ps1)",
        "#",
        "# Source : fleet.yaml",
        "",
        'Set-StrictMode -Version Latest',
        '$ErrorActionPreference = "Stop"',
        "",
        "# WSL_ROOT : charge depuis config.local.ps1 (cree par Instanciator.ps1 au 1er run)",
        '$ConfigFile = "$PSScriptRoot\\..\\..\\config.local.ps1"',
        'if (Test-Path $ConfigFile) { . (Resolve-Path $ConfigFile) }',
        'else { $WSL_ROOT = Read-Host "WSL root directory (ex: C:\\Users\\$env:USERNAME\\WSL)" }',
        "",
        f'$SOURCES_DIR = "$WSL_ROOT\\{sources_subdir}"',
        '$SETUP_SH    = "$PSScriptRoot\\wsl-setup.sh"',
        "",
    ]

    for inst in instances:
        name = inst["wsl-name"]
        itype = inst["instance-type"]
        user = inst["user"]
        desc = inst.get("description", "")

        lines += [
            f"# --- {name} ({inst['role']}) ---",
        ]
        if desc:
            lines.append(f"# {desc}")
        lines += [
            f'Write-Host "Deploiement de {name}..." -ForegroundColor Cyan',
            f'& "$PSScriptRoot\\Instanciator.ps1" '
            f'-Name "{name}" '
            f'-Username "{user}" '
            f'-InstanceType "{itype}"',
            "",
        ]

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Génère un script PS1 depuis fleet.yaml")
    parser.add_argument("--output", default="deploy-fleet.ps1",
                        help="Fichier PS1 de sortie (défaut: deploy-fleet.ps1)")
    parser.add_argument("--instance", metavar="ID",
                        help="Déployer une seule instance (filtre par id)")
    parser.add_argument("--list", action="store_true",
                        help="Lister les instances définies dans fleet.yaml")
    args = parser.parse_args()

    if not FLEET_YAML.exists():
        print(f"Erreur : {FLEET_YAML} introuvable", file=sys.stderr)
        sys.exit(1)

    data = load_fleet(FLEET_YAML)
    errors = validate_fleet(data)
    if errors:
        for e in errors:
            print(f"Erreur validation : {e}", file=sys.stderr)
        sys.exit(1)

    instances = data["instances"]

    if args.list:
        print(f"{'ID':<22} {'WSL-NAME':<22} {'ROLE':<18} {'TYPE':<12} {'MEM'}")
        print("-" * 85)
        for inst in instances:
            print(f"{inst['id']:<22} {inst['wsl-name']:<22} {inst['role']:<18} "
                  f"{inst['instance-type']:<12} {inst.get('memory', '-')}")
        return

    if args.instance:
        instances = [i for i in instances if i["id"] == args.instance]
        if not instances:
            print(f"Erreur : instance '{args.instance}' introuvable dans fleet.yaml", file=sys.stderr)
            sys.exit(1)

    ps1_content = generate_ps1(data, instances)
    output_path = Path(args.output)
    output_path.write_text(ps1_content, encoding="utf-8-sig")
    print(f"Genere : {output_path} ({len(instances)} instance(s))")
    print(f"Executer depuis PowerShell : .\\{output_path.name}")


if __name__ == "__main__":
    main()
