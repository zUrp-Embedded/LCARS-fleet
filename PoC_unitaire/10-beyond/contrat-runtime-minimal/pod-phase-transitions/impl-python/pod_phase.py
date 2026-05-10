#!/usr/bin/env python3
# SOURCE: pod_phase.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Machine a etats PodStatus.phase.
# Source : beyond-contrat-runtime-minimal.md §3.

from enum import Enum


class PodPhase(str, Enum):
    PENDING = "Pending"
    RUNNING = "Running"
    SUCCEEDED = "Succeeded"
    FAILED = "Failed"
    UNKNOWN = "Unknown"


# None = transition depuis "rien" (creation)
TRANSITIONS = {
    (None, PodPhase.PENDING),
    (PodPhase.PENDING, PodPhase.RUNNING),
    (PodPhase.PENDING, PodPhase.FAILED),
    (PodPhase.RUNNING, PodPhase.SUCCEEDED),
    (PodPhase.RUNNING, PodPhase.FAILED),
    (PodPhase.RUNNING, PodPhase.UNKNOWN),
    (PodPhase.UNKNOWN, PodPhase.FAILED),
}

TERMINAL = {PodPhase.SUCCEEDED, PodPhase.FAILED}


class IllegalTransition(ValueError):
    pass


def transition(from_phase, to_phase):
    """Valide une transition. Raise IllegalTransition si interdite."""
    if from_phase in TERMINAL:
        raise IllegalTransition(
            f"{from_phase} is terminal, cannot transition to {to_phase}"
        )
    if (from_phase, to_phase) not in TRANSITIONS:
        raise IllegalTransition(
            f"{from_phase} -> {to_phase} not allowed"
        )
    return to_phase
