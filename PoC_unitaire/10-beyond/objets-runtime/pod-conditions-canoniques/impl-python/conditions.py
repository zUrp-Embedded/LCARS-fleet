#!/usr/bin/env python3
# SOURCE: conditions.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-objets-runtime-v2.md §1 "Conditions canoniques"

# Set canonique des 6 conditions PodStatus
CANONICAL_CONDITIONS = {
    "HomeProjected",
    "ContextInjected",
    "ProcessLaunched",
    "StreamAlive",
    "OutputExtracted",
    "HomeReleased",
}

# Ordre monotone (les conditions qui ne togglent pas). StreamAlive est
# la seule qui peut revenir a False (liveness fail).
MONOTONE_ORDER = [
    "HomeProjected",     # PROJECT
    "ContextInjected",   # INJECT
    "ProcessLaunched",   # LAUNCH
    "OutputExtracted",   # EXTRACT
    "HomeReleased",      # RELEASE
]

# Mapping condition -> etape du spawn cycle (reference beyond-contrat-
# runtime-minimal §2 Cycle spawn).
EMITTED_AT = {
    "HomeProjected": "PROJECT",
    "ContextInjected": "INJECT",
    "ProcessLaunched": "LAUNCH",
    "StreamAlive": "MONITOR",
    "OutputExtracted": "EXTRACT",
    "HomeReleased": "RELEASE",
}


def is_monotone(condition_name):
    """True si la condition ne peut pas toggler (monotone -> True)."""
    if condition_name not in CANONICAL_CONDITIONS:
        raise ValueError(f"unknown condition: {condition_name}")
    return condition_name in MONOTONE_ORDER
