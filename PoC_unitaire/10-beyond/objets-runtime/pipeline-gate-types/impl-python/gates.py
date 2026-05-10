#!/usr/bin/env python3
# SOURCE: gates.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-objets-runtime-v2.md §3

ALLOWED_GATE_TYPES = {"hard", "soft", "terminal"}
ALLOWED_TERMINAL_OUTCOMES = {"promote", "retry", "escalate"}


class InvalidGate(ValueError):
    pass


def evaluate_gate(gate_type, result, on_fail_spec=None):
    """
    gate_type: hard | soft | terminal
    result: pour hard/soft = 'pass' | 'fail' ; pour terminal = 'promote' | 'retry' | 'escalate'
    on_fail_spec: pour hard, string comme 'retry-engineer' ou 'escalate-gatekeeper'

    Retourne l action suivante (string).
    """
    if gate_type not in ALLOWED_GATE_TYPES:
        raise InvalidGate(f"unknown gate type: {gate_type}")

    if gate_type == "hard":
        if result == "pass":
            return "continue"
        if result == "fail":
            if not on_fail_spec:
                raise InvalidGate("hard gate FAIL requires on_fail_spec")
            return on_fail_spec
        raise InvalidGate(f"hard gate result must be pass|fail, got {result!r}")

    if gate_type == "soft":
        # Advisory : n interrompt jamais. Continue quel que soit le result.
        return "continue"

    # terminal
    if result not in ALLOWED_TERMINAL_OUTCOMES:
        raise InvalidGate(
            f"terminal gate result must be {sorted(ALLOWED_TERMINAL_OUTCOMES)}, got {result!r}"
        )
    return {
        "promote": "create_delivery",
        "retry": "retry_attempt",
        "escalate": "escalate_architect",
    }[result]


def validate_pipeline_gates(stages):
    """
    stages: dict {name: {..., 'gate': {'type': ...}}}
    Raise InvalidGate si :
    - un gate type est inconnu
    - plusieurs gates terminal (doit y en avoir au plus 1)
    """
    terminal_count = 0
    for name, spec in stages.items():
        gate = spec.get("gate")
        if not gate:
            continue
        t = gate.get("type")
        if t not in ALLOWED_GATE_TYPES:
            raise InvalidGate(f"stage {name!r} has unknown gate type {t!r}")
        if t == "terminal":
            terminal_count += 1

    if terminal_count > 1:
        raise InvalidGate(
            f"pipeline has {terminal_count} terminal gates, at most 1 allowed"
        )
