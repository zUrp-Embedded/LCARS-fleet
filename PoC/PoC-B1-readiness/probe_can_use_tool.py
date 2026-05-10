#!/usr/bin/env python3
# SOURCE: probe_can_use_tool.py
# AUTHOR: STARFLEET
# STARDATE: 2026.110
# STATUS: PoC done
# B1b — can_use_tool callback (permission bridging).
#
# Tester le hook dynamique qui permet au host de decider tool-par-tool si
# l invocation passe. Gatekeeper LCARS depend de ce hook.
# On pose une policy : denial pour inputs contenant "SECRET", allow sinon.
# Verifier que :
#   - appel beningn -> allow -> tool run -> marker dans reponse
#   - appel avec "SECRET" -> deny -> tool_result is_error -> agent continue

import asyncio
import json
import os
import uuid
from claude_agent_sdk import (
    tool,
    create_sdk_mcp_server,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultAllow,
    PermissionResultDeny,
)

BENIGN_MARK = f"BENIGN-{uuid.uuid4().hex[:8]}"


@tool("risky_op", "Runs a sensitive operation with arbitrary payload.", {"payload": str})
async def risky_op(args):
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps({"status": "done", "marker": BENIGN_MARK, "payload": args.get("payload")}),
            }
        ]
    }


server = create_sdk_mcp_server(name="lcars-b1b", version="0.1.0", tools=[risky_op])


denied_calls = []
allowed_calls = []


async def can_use_tool(tool_name, input_data, context):
    # Policy : refuser si payload contient "BLOCKME" (choisi neutre pour ne
    # pas declencher auto-censure LLM — le model call le tool, le hook tranche).
    payload = (input_data or {}).get("payload", "") or ""
    print(f"    [HOOK] can_use_tool tool={tool_name} payload={payload!r}")
    if "BLOCKME" in payload.upper():
        denied_calls.append({"tool": tool_name, "payload": payload, "tool_use_id": context.tool_use_id})
        return PermissionResultDeny(message="policy: BLOCKME payload rejected by host", interrupt=False)
    allowed_calls.append({"tool": tool_name, "payload": payload, "tool_use_id": context.tool_use_id})
    return PermissionResultAllow()


async def run_once(prompt, label):
    # NOTE : ne pas mettre allowed_tools=[...] — ca pre-autorise le tool et
    # le callback can_use_tool n est pas invoque. Strategie : declarer le
    # tool dans mcp_servers, pas de allowed_tools, permission_mode=default,
    # le callback decide.
    options = ClaudeAgentOptions(
        mcp_servers={"lcars": server},
        model="haiku",
        permission_mode="default",
        max_turns=6,
        setting_sources=[],
        can_use_tool=can_use_tool,
    )
    final = None
    tool_results = []
    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt)
        async for msg in client.receive_response():
            if getattr(msg, "result", None):
                final = msg.result
            content = getattr(msg, "content", None)
            if isinstance(content, list):
                for b in content:
                    if type(b).__name__ == "ToolResultBlock":
                        tool_results.append(b)
    return {"label": label, "final": final, "tool_results": tool_results}


async def main():
    print(f"[INFO] python pid: {os.getpid()}")

    # T1 : appel benin -> allow
    print("[INFO] T1 benign call...")
    r1 = await run_once(
        f"Call risky_op with payload='hello world'. Then echo EXACTLY the marker from the tool response, nothing else.",
        "T1-benign",
    )
    print(f"  final: {(r1['final'] or '')[:120]}")
    if BENIGN_MARK in (r1["final"] or "") and len(allowed_calls) >= 1 and len(denied_calls) == 0:
        print(f"  [PASS] T1 benign allowed, marker relayed")
    else:
        print(
            f"  [FAIL] T1 benign — allowed={len(allowed_calls)} denied={len(denied_calls)} final={r1['final']!r}"
        )

    allowed_calls.clear()
    denied_calls.clear()

    # T2 : appel bloque par policy -> deny -> agent recoit tool_result is_error
    print("[INFO] T2 BLOCKME call...")
    r2 = await run_once(
        "Call risky_op with payload='BLOCKME flag'. "
        "If the tool returns an error (including policy denial), reply exactly: DENIED_OK. Do not retry.",
        "T2-blockme",
    )
    print(f"  final: {(r2['final'] or '')[:120]}")
    print(f"  allowed={len(allowed_calls)} denied={len(denied_calls)}")
    tool_errors = [
        tr for tr in r2["tool_results"] if getattr(tr, "is_error", False)
    ]
    print(f"  tool_errors visible: {len(tool_errors)}")
    for te in tool_errors[:2]:
        print(f"    content snippet: {str(getattr(te, 'content', None))[:120]}")

    if len(denied_calls) >= 1 and len(tool_errors) >= 1:
        print(f"  [PASS] T2 SECRET denied + agent sees is_error")
    else:
        print(
            f"  [FAIL] T2 SECRET — denied={len(denied_calls)} is_error={len(tool_errors)}"
        )

    print()
    print("===== BILAN B1b =====")
    print(f"denial events captured: {[d['payload'] for d in denied_calls]}")
    print(f"allow events captured: {[a['payload'] for a in allowed_calls]}")


if __name__ == "__main__":
    asyncio.run(main())
