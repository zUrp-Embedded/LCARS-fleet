#!/bin/bash
# SOURCE: test.sh
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: DRAFT
echo "[GAP] extract pipeline 7 etapes + crash injection requiert impl-python/extract_pipeline.py"
echo "[GAP] harness : multiprocessing + SIGKILL a chaque etape N, verify invariant post-crash"
echo "[GAP] recovery rule : artefacts sans event -> rollback ; event sans artefacts -> fatal"
echo "[GAP] prerequis croises : extract-primitives-fs PROVEN, event-log-ndjson PROVEN, pod-phase-transitions PROVEN"
exit 0
