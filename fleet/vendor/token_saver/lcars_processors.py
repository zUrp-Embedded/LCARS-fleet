# SOURCE: fleet/vendor/token_saver/lcars_processors.py
# AUTHOR: starfleet
# STARDATE: 2026-08-04
# STATUS: processeurs LCARS — safe_build_process (F6 : ne jamais affirmer un succes non constate)
"""Correctifs de processeurs — couche LCARS.

Fichier LCARS, hors sous-arbre vendoré. Corrige un finding du reverse sans
modifier une ligne de `src/`, pour que le merge amont reste trivial (VENDOR.md).

La substitution se fait par remplacement de méthode sur la classe amont, et non
par sous-classement : deux classes de même `name` et même priorité dans un
registre trié sur `(priority, name)` auraient réintroduit le non-déterminisme
de routage que l'amont a précisément corrigé. L'adapter s'en charge au boot.
"""

from __future__ import annotations

import re

# ── F6 — `build` affirmait le succès faute d'avoir reconnu un échec ───────────
#
# Le processeur amont décide ainsi (`src/processors/build_output.py:70-79`) :
#
#     has_error = any(re.search(r"\b(error|Error|ERROR)\b", line) ...)
#     if has_error: return self._extract_errors(lines)
#     return self._summarize_success(lines)      # → "Build succeeded."
#
# Mesuré au reverse : 401 lignes contenant
# `/usr/bin/ld: undefined reference to `codec_init'` deviennent
# `'Build succeeded.'`. Ce n'est pas une perte d'information, c'est une
# **inversion de sens** — l'agent reçoit une affirmation positive fausse.
#
# Règle retenue : ne jamais affirmer un succès qu'on n'a pas constaté. À défaut
# de motif reconnu dans un sens ou dans l'autre, on ne conclut pas — la sortie
# est rendue inchangée et le moteur enchaîne sur le repli générique, qui tronque
# en laissant un marqueur.

FAILURE_RE = re.compile(
    r"(?:^|\W)(?:"
    r"undefined\s+reference|multiple\s+definition|cannot\s+find\s+-l|"
    r"segmentation\s+fault|core\s+dumped|bus\s+error|"
    r"FAILED|FAIL\b|failure|failed\s+with|"
    r"no\s+such\s+file|permission\s+denied|command\s+not\s+found|"
    r"recipe\s+for\s+target.*failed|make.*\*\*\*|"
    r"ninja:\s+build\s+stopped|linker\s+command\s+failed|"
    r"collect2:|ld\s+returned|exit\s+status\s+[1-9]"
    r")",
    re.IGNORECASE,
)

SUCCESS_RE = re.compile(
    r"(?:^|\W)(?:"
    r"build\s+succe|successfully\s+built|compiled\s+successfully|"
    r"build\s+complete|done\s+in\s+|finished\s+(?:in|release|dev)|"
    r"0\s+errors?|no\s+errors?|up\s+to\s+date|"
    r"webpack\s+compiled|built\s+in\s+|added\s+\d+\s+packages"
    r")",
    re.IGNORECASE,
)

_AMONT_ERROR_RE = re.compile(r"\b(error|Error|ERROR)\b")
_ZERO_ERRORS_RE = re.compile(r"\b0 errors?\b")
_SPECIALISES_RE = re.compile(
    r"\b(npm|yarn|pnpm)\s+audit\b|\bdocker\s+(build|compose\s+build)\b"
)


def extract_failure_context(lines: list[str]) -> str:
    """Garde les lignes d'échec avec leur contexte, plus la queue du flux."""
    keep: set[int] = set()
    for i, ln in enumerate(lines):
        if FAILURE_RE.search(ln):
            keep.update(range(max(0, i - 2), min(len(lines), i + 3)))
    keep.update(range(max(0, len(lines) - 5), len(lines)))

    out: list[str] = []
    prev = -2
    for i in sorted(keep):
        if i > prev + 1 and prev >= 0:
            out.append("  ... (%d lignes omises)" % (i - prev - 1))
        out.append(lines[i])
        prev = i
    out.append("[token-saver] échec détecté par motif étendu — %d lignes au total" % len(lines))
    return "\n".join(out)


def safe_build_process(self, command: str, output: str) -> str:
    """Remplace `BuildOutputProcessor.process`. Voir F6 ci-dessus."""
    if not output or not output.strip():
        return output

    # Chemins spécialisés de l'amont (tsc --noEmit, audit, docker build) : ils
    # ont leur propre logique et ne passent pas par le résumé de succès.
    if re.search(r"\btsc\b.*--noEmit", command) or _SPECIALISES_RE.search(command):
        return _upstream_process(self, command, output)

    lines = output.splitlines()
    amont_voit_erreur = any(
        _AMONT_ERROR_RE.search(ln)
        and not _ZERO_ERRORS_RE.search(ln)
        and not self._is_progress_line(ln.strip())
        for ln in lines
    )
    if amont_voit_erreur:
        return _upstream_process(self, command, output)

    # Échec que le motif amont ne voit pas → extraction, jamais résumé de succès.
    if any(FAILURE_RE.search(ln) for ln in lines):
        return extract_failure_context(lines)

    # Ni échec ni succès explicite : ne rien affirmer, laisser passer.
    if not any(SUCCESS_RE.search(ln) for ln in lines):
        return output

    return _upstream_process(self, command, output)


# Capturé à l'import, avant toute substitution par l'adapter.
def _capture_upstream():
    from src.processors.build_output import BuildOutputProcessor

    return BuildOutputProcessor.process


_upstream_process = _capture_upstream()
