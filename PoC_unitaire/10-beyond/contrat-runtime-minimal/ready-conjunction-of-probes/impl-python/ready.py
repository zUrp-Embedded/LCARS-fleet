#!/usr/bin/env python3
# SOURCE: ready.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl trivial mais normed
# Source : beyond-contrat-runtime-minimal.md §3 "Système READY"

EXPECTED_PROBES = {
    "runtime_exists",
    "specs_readable",
    "credentials_avail",
    "event_log_writable",
    "pool_users_exist",
    "fleet_pilot_up",
}


def is_ready(probe_results):
    """
    probe_results: dict[str, bool] — nom de probe vers booleen.
    Returns True ssi toutes les probes attendues sont presentes ET True.
    """
    if set(probe_results.keys()) != EXPECTED_PROBES:
        missing = EXPECTED_PROBES - set(probe_results.keys())
        extra = set(probe_results.keys()) - EXPECTED_PROBES
        raise ValueError(f"probe set mismatch. missing={missing} extra={extra}")
    return all(probe_results.values())
