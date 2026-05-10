#!/usr/bin/env python3
# SOURCE: probe_concurrent.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# B1a — multi-agent concurrent.
#
# Spawn N agents via asyncio.gather sur query() — chacun avec son propre
# in-process MCP server + son marker unique. Verifier :
#   - tous aboutissent
#   - reponse de chacun contient SON marker (pas de cross-contamination)
#   - duree totale ~ parallele (pas N x duree seule)

import asyncio
import json
import os
import time
import uuid
from claude_agent_sdk import (
    tool,
    create_sdk_mcp_server,
    ClaudeAgentOptions,
    query,
)

N_AGENTS = 4


def make_agent(idx: int):
    marker = f"AGT{idx}-{uuid.uuid4().hex[:8]}"
    pid_seen = []

    @tool(
        f"get_marker_{idx}",
        "Retourne le marker unique de cet agent.",
        {},
    )
    async def get_marker(args):
        pid_seen.append(os.getpid())
        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps({"marker": marker, "agent": idx}),
                }
            ]
        }

    server = create_sdk_mcp_server(
        name=f"lcars-b1a-{idx}",
        version="0.1.0",
        tools=[get_marker],
    )

    async def run_one():
        t0 = time.monotonic()
        options = ClaudeAgentOptions(
            mcp_servers={f"lcars": server},
            allowed_tools=[f"mcp__lcars__get_marker_{idx}"],
            model="haiku",
            permission_mode="bypassPermissions",
            max_turns=4,
            setting_sources=[],
        )
        prompt = (
            f"Call tool mcp__lcars__get_marker_{idx} with no args. "
            f"Then echo exactly the marker string from the tool response, nothing else."
        )
        final = None
        events = 0
        async for msg in query(prompt=prompt, options=options):
            events += 1
            if getattr(msg, "result", None):
                final = msg.result
        dur = time.monotonic() - t0
        return {
            "idx": idx,
            "marker": marker,
            "final": final,
            "events": events,
            "duration_s": dur,
            "tool_pids": pid_seen,
        }

    return marker, run_one


async def main():
    print(f"[INFO] python pid: {os.getpid()}")
    print(f"[INFO] spawning {N_AGENTS} agents concurrent")

    tasks = []
    markers = []
    for i in range(N_AGENTS):
        marker, fn = make_agent(i)
        markers.append(marker)
        tasks.append(fn())

    t0 = time.monotonic()
    results = await asyncio.gather(*tasks, return_exceptions=True)
    t_total = time.monotonic() - t0

    print(f"[INFO] duree totale gather: {t_total:.2f}s")
    print()

    ok_agents = 0
    for r in results:
        if isinstance(r, Exception):
            print(f"[FAIL] agent exception: {r!r}")
            continue
        marker_expected = r["marker"]
        final = r["final"] or ""
        print(
            f"[INFO] agent {r['idx']}: dur={r['duration_s']:.2f}s "
            f"events={r['events']} pids={set(r['tool_pids'])}"
        )
        print(f"  expected marker: {marker_expected}")
        print(f"  final response : {final[:100]}")
        # check marker appears in final AND no other agent's marker bled in
        other = [m for m in markers if m != marker_expected]
        if marker_expected in final and not any(m in final for m in other):
            ok_agents += 1
            print(f"  [PASS] marker isolation OK")
        else:
            print(f"  [FAIL] marker isolation KO")

    print()
    print("===== BILAN B1a =====")
    print(f"agents OK: {ok_agents}/{N_AGENTS}")
    # check parallelism: total time < sum of individual durations
    durations = [r["duration_s"] for r in results if not isinstance(r, Exception)]
    serial = sum(durations)
    if durations:
        speedup = serial / t_total if t_total > 0 else 0
        print(
            f"duration total={t_total:.2f}s, sum_seq={serial:.2f}s, speedup~{speedup:.2f}x"
        )
        if speedup > 1.5:
            print(f"[PASS] parallelism (speedup {speedup:.2f}x > 1.5x)")
        else:
            print(f"[FAIL] parallelism (speedup {speedup:.2f}x <= 1.5x = serialisation)")


if __name__ == "__main__":
    asyncio.run(main())
