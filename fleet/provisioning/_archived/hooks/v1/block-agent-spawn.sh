#!/bin/bash
# PreToolUse hook — blocks Agent tool for non-Tier-1 instances.
# Deploy to instances that must NOT spawn sub-agents.
# Tier 1 (engineer) does NOT get this hook.

TOOL_NAME=$(cat | jq -r '.tool_name // empty' 2>/dev/null)

if [[ "$TOOL_NAME" == "Agent" ]]; then
    echo '{"decision": "block", "reason": "Agent spawn interdit pour cette instance. Escalader vers engineer via fleet-send.sh."}'
    exit 0
fi
