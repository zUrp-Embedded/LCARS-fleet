#!/usr/bin/env python3
# SOURCE: dag.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: impl candidate pour fleet-pilot
# Source : beyond-objets-runtime-v2.md §3 Invariant 1

class CycleDetected(ValueError):
    pass


class UnknownStage(ValueError):
    pass


def validate_dag(pipeline_stages):
    """
    pipeline_stages: dict {stage_name: {..., 'needs': [name, ...]}}
    Raise CycleDetected si un cycle est present.
    Raise UnknownStage si un needs reference un stage inexistant.
    """
    names = set(pipeline_stages.keys())

    # 1. Tous les needs referencent des stages definis
    for name, spec in pipeline_stages.items():
        for n in spec.get("needs", []):
            if n not in names:
                raise UnknownStage(f"stage {name!r} needs unknown stage {n!r}")

    # 2. DFS avec 3 etats : UNSEEN / VISITING / DONE
    UNSEEN, VISITING, DONE = 0, 1, 2
    state = {n: UNSEEN for n in names}

    def dfs(n, path):
        if state[n] == DONE:
            return
        if state[n] == VISITING:
            cycle = path[path.index(n):] + [n]
            raise CycleDetected(f"cycle: {' -> '.join(cycle)}")
        state[n] = VISITING
        for dep in pipeline_stages[n].get("needs", []):
            dfs(dep, path + [n])
        state[n] = DONE

    for n in names:
        if state[n] == UNSEEN:
            dfs(n, [])
