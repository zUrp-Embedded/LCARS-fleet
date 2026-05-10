#!/usr/bin/env python3
# SOURCE: attempt_phase.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot

from enum import Enum


class AttemptPhase(str, Enum):
    PENDING = "Pending"
    RUNNING = "Running"
    SUCCEEDED = "Succeeded"
    FAILED = "Failed"
    INTERRUPTED = "Interrupted"
    LOST = "Lost"


TRANSITIONS = {
    (None, AttemptPhase.PENDING),
    (AttemptPhase.PENDING, AttemptPhase.RUNNING),
    (AttemptPhase.RUNNING, AttemptPhase.SUCCEEDED),
    (AttemptPhase.RUNNING, AttemptPhase.FAILED),
    (AttemptPhase.RUNNING, AttemptPhase.INTERRUPTED),
    (AttemptPhase.RUNNING, AttemptPhase.LOST),
    (AttemptPhase.RUNNING, AttemptPhase.RUNNING),
}

TERMINAL = {
    AttemptPhase.SUCCEEDED,
    AttemptPhase.FAILED,
    AttemptPhase.INTERRUPTED,
    AttemptPhase.LOST,
}


class IllegalTransition(ValueError):
    pass


def transition(from_phase, to_phase):
    if from_phase in TERMINAL:
        raise IllegalTransition(f"{from_phase} is terminal")
    if (from_phase, to_phase) not in TRANSITIONS:
        raise IllegalTransition(f"{from_phase} -> {to_phase} not allowed")
    return to_phase
