#!/usr/bin/env python3
# SOURCE: gate_data.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-contrat-runtime-minimal.md §4

import re

ALLOWED_COMPILATION = {"clean", "errors", "warnings"}
ALLOWED_LINT = {"clean", "errors", "warnings"}
ALLOWED_TYPECHECK = {"clean", "errors", "n/a"}


def extract_gate_data(report_text):
    """
    Extract le bloc yaml gate_data du rapport. Retourne dict ou None.
    Recherche la DERNIERE occurrence non-commentee (le gate data est en
    fin de rapport, et un bloc commente en haut ne doit pas le shadow).

    R-07 fix (consultant 2026-04-20) : skip les lignes commentees (# ...)
    au niveau de la detection "gate_data:". Si multiple blocs existent,
    prendre le dernier (qui matche effectivement la docstring).
    """
    # Masquer les lignes qui commencent par # avant extraction
    # (pas strictement du YAML mais accepte la coutume markdown)
    masked_lines = []
    for line in report_text.splitlines():
        if re.match(r"^\s*#", line):
            masked_lines.append("")  # preserve line count, efface le contenu
        else:
            masked_lines.append(line)
    masked = "\n".join(masked_lines)

    # Prendre la DERNIERE occurrence — findall puis [-1]
    matches = list(re.finditer(
        r"gate_data\s*:\s*\n((?:[ \t]+\w[^\n]*\n?)+)",
        masked,
    ))
    if not matches:
        return None
    m = matches[-1]
    body = m.group(1)
    d = {}
    for line in body.splitlines():
        if not line.strip():
            continue
        # parse "key: value" avec commentaire optionnel
        kv = re.match(r"\s*([\w_]+)\s*:\s*([^\s#]+)", line)
        if kv:
            key, val = kv.group(1), kv.group(2)
            # int si possible
            try:
                val = int(val)
            except ValueError:
                pass
            d[key] = val
    return d


def evaluate_gate(report_text):
    """
    Retourne ("PASS"|"FAIL", reason).
    Fail-closed : report_text sans gate_data = FAIL.
    """
    data = extract_gate_data(report_text)
    if data is None:
        return ("FAIL", "gate_data block absent — fail-closed")

    # F3 fix (vulcan 2026-04-20): le contrat mandat.md impose 5 champs
    # obligatoires (tests_total, tests_passed, compilation, lint, type_check).
    # La version precedente n en verifiait que 3. Aligne avec le mandat.
    required = {"tests_total", "tests_passed", "compilation", "lint", "type_check"}
    missing = required - set(data.keys())
    if missing:
        return ("FAIL", f"gate_data missing fields: {sorted(missing)}")

    if not isinstance(data.get("tests_total"), int) or not isinstance(
        data.get("tests_passed"), int
    ):
        return ("FAIL", "tests_total/tests_passed not integers")

    if data.get("compilation") not in ALLOWED_COMPILATION:
        return ("FAIL", f"compilation must be one of {sorted(ALLOWED_COMPILATION)}")

    if data.get("lint") not in ALLOWED_LINT:
        return ("FAIL", f"lint must be one of {sorted(ALLOWED_LINT)}")

    if data.get("type_check") not in ALLOWED_TYPECHECK:
        return ("FAIL", f"type_check must be one of {sorted(ALLOWED_TYPECHECK)}")

    # R-07 fix : rejeter overshoot (tests_passed > tests_total = inconsistant)
    if data["tests_passed"] > data["tests_total"]:
        return ("FAIL", f"tests_passed={data['tests_passed']} > tests_total={data['tests_total']} (overshoot)")

    # R-07 fix : rejeter tests_total = 0 (pas de tests = pas de gate valide)
    if data["tests_total"] <= 0:
        return ("FAIL", f"tests_total={data['tests_total']} (must be > 0)")

    if data["tests_passed"] < data["tests_total"]:
        return ("FAIL", f"{data['tests_passed']}/{data['tests_total']} tests")

    if data["compilation"] != "clean":
        return ("FAIL", f"compilation={data['compilation']}")

    if data["lint"] != "clean":
        return ("FAIL", f"lint={data['lint']}")

    # type_check : "n/a" est valide (pas de type system dans le stack),
    # sinon exige "clean".
    if data["type_check"] not in ("clean", "n/a"):
        return ("FAIL", f"type_check={data['type_check']}")

    return ("PASS", "all criteria met")
