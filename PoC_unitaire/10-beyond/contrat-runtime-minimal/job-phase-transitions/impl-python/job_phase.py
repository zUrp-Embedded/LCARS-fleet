#!/usr/bin/env python3
# SOURCE: job_phase.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-contrat-runtime-minimal.md §3 "Job.status.phase"

from enum import Enum


class JobPhase(str, Enum):
    PENDING = "Pending"
    RUNNING = "Running"
    SUCCEEDED = "Succeeded"
    FAILED = "Failed"
    ABORTED = "Aborted"
    SUSPENDED = "Suspended"


TRANSITIONS = {
    (None, JobPhase.PENDING),
    (JobPhase.PENDING, JobPhase.RUNNING),
    (JobPhase.RUNNING, JobPhase.SUCCEEDED),
    (JobPhase.RUNNING, JobPhase.FAILED),
    (JobPhase.RUNNING, JobPhase.ABORTED),
    (JobPhase.RUNNING, JobPhase.SUSPENDED),
    (JobPhase.SUSPENDED, JobPhase.RUNNING),
    (JobPhase.SUSPENDED, JobPhase.ABORTED),
    (JobPhase.RUNNING, JobPhase.RUNNING),  # retry
}

TERMINAL = {JobPhase.SUCCEEDED, JobPhase.FAILED, JobPhase.ABORTED}


class IllegalTransition(ValueError):
    pass


def transition(from_phase, to_phase):
    if from_phase in TERMINAL:
        raise IllegalTransition(f"{from_phase} is terminal")
    if (from_phase, to_phase) not in TRANSITIONS:
        raise IllegalTransition(f"{from_phase} -> {to_phase} not allowed")
    return to_phase
