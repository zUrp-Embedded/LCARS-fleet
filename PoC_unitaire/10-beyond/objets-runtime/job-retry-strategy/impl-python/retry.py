#!/usr/bin/env python3
# SOURCE: retry.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-objets-runtime-v2.md §2 "Retry"

from enum import Enum


class RetryDecision(str, Enum):
    RETRY = "retry"
    ESCALATE_FAILED = "escalate_failed"
    ESCALATE_ABORTED = "escalate_aborted"


def decide_retry(reason, attempts, strategy):
    """
    reason: str
    attempts: int (nombre d attempts deja effectues, incluant celui qui vient de terminer)
    strategy: dict {maxAttempts: int, retryOn: list[str], noRetryOn: list[str]}

    Retourne un RetryDecision.
    """
    # Branch Interrupted : decision explicite, pas retry
    if reason == "interrupted":
        return RetryDecision.ESCALATE_ABORTED

    max_attempts = strategy.get("maxAttempts", 1)
    retry_on = set(strategy.get("retryOn", []))
    no_retry_on = set(strategy.get("noRetryOn", []))

    # noRetryOn prime (fail-closed si listes se chevauchent)
    if reason in no_retry_on:
        return RetryDecision.ESCALATE_FAILED

    # retryOn + budget -> retry
    if reason in retry_on and attempts < max_attempts:
        return RetryDecision.RETRY

    # retryOn epuise ou raison non listee -> escalate
    return RetryDecision.ESCALATE_FAILED
