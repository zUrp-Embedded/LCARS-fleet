#!/usr/bin/env bash
# SOURCE: test/gate-u-rc-e2e.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-u-rc-e2e.sh — e2e LLM attestation du pivot RC (TmuxBackend + ticket-driven PULL).
#
# Preuve mécanique exit 0 ssi la CHAÎNE COMPLÈTE tient :
#   1. Fleet.MCP.TaskQueue.push(task_avec_nonce)  → file centrale chargée
#   2. Fleet.Spawner.spawn_pod (TmuxBackend)     → tmux session up
#   3. claude --remote-control démarre, bridge.py spawné via .mcp-fleet.json
#   4. pod.ex inject_brief_to_tmux_pod → send-keys "yop" (mot-clé protocole-user)
#   5. claude REPL : voit son SP draft (agent-worker-base + protocole-user.md)
#      → "yop" déclenche workflow → appelle mcp__fleet__get_task
#   6. Central PodTools renvoie la task (avec nonce) → claude traite →
#      mcp__fleet__submit_result avec payload contenant le nonce
#   7. Central broadcast pod.result_submitted → pod.ex handle_info → extract
#   8. pod.ex broadcast pod.completed → gate reçoit + assert nonce match
#   9. release path → kill_session tmux
#
# Pré-requis : OAuth ~/.claude/.credentials.json (Claude Max), claude binary +
# tmux dans PATH. Containment dégradé (POC scope) : HOME=$POD_DIR isolé via
# tmux -e, pas de bwrap.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="$(cd "$HERE/.." && pwd)"
BIN="$RT/bin"
ENG_SRC="$RT/apps/fleet_capprofile/priv/canon/cap-profiles/engineer.yaml"
# protocole-user worker = default pod.ex (priv/sp_drafts/protocole-user-worker.md).
# Pas de PROTOCOLE_USER_SRC : on N'INJECTE PAS un protocole d'instance humaine
# (yop neutralisé / "lire handoff") qui empêcherait le workflow worker.
WORK="$(mktemp -d -p /var/tmp lcars-gate-u-rc.XXXXXX)"
BINV="$(mktemp -d -p /var/tmp lcars-gate-u-rc-bin.XXXXXX)"

cp "$BIN/fleet_mcp_stdio_bridge.py" "$BINV/"

POD_ID="urc-$(date +%s)-$RANDOM"
POD_DIR="$WORK/pods/pod-$POD_ID"
SESSION="lcars-$POD_ID"
NONCE="urc-$(date +%s)-$RANDOM"

trap '
  if [ "${KEEP:-0}" = 1 ]; then
    echo "KEEP $WORK $BINV $SESSION (tmux session laissée vivante pour debug)"
  else
    tmux kill-session -t "$SESSION" 2>/dev/null
    pkill -f "$WORK" 2>/dev/null || true
    rm -rf "$WORK" "$BINV"
  fi
' EXIT

# Pré-flight
command -v tmux >/dev/null || { echo "FAIL: tmux absent du PATH"; exit 2; }
command -v claude >/dev/null || { echo "FAIL: claude absent du PATH"; exit 2; }
[ -f /home/starfleet/.claude/.credentials.json ] || { echo "FAIL: OAuth creds absentes"; exit 2; }

mkdir -p "$WORK/pods" "$WORK/state" "$WORK/coffre/engineer" \
         "$WORK/sp" "$WORK/capprofile/modop/noop"
printf '# Engineer SP base\n' > "$WORK/sp/engineer-role.md"

# OAuth single-file coffre (Vulcan #6).
python3 - "$WORK/coffre/engineer" <<'PY'
import json, sys, os
d = json.load(open('/home/starfleet/.claude/.credentials.json'))['claudeAiOauth']
b = sys.argv[1]
coffre = {
    'refresh_token': d['refreshToken'],
    'access_token': d['accessToken'],
    'scopes': ' '.join(d.get('scopes', [])),
    'expires_at': d.get('expiresAt', 9999999999999),
}
open(os.path.join(b, 'coffre.json'), 'w').write(json.dumps(coffre, indent=2))
PY

# Pré-provision POD_DIR (HOME isolé du pod en POC sans bwrap).
mkdir -p "$POD_DIR/.claude"
cp /home/starfleet/.claude/.credentials.json "$POD_DIR/.claude/"
VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 2.1.150)"
cat > "$POD_DIR/.claude.json" <<JSON
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "$VER",
  "migrationVersion": 13,
  "projects": {
    "$POD_DIR": {
      "allowedTools": [],
      "hasTrustDialogAccepted": true,
      "projectOnboardingSeenCount": 10
    }
  }
}
JSON

# Cap-profile (engineer + mcp__fleet__* tools auto-approuvés).
cp "$ENG_SRC" "$WORK/capprofile/engineer.yaml"
sed -i '/^    allowedTools:/a\      - mcp__fleet__get_task\n      - mcp__fleet__submit_result' "$WORK/capprofile/engineer.yaml"
sed -i 's|^    libs:$|    libs: []|' "$WORK/capprofile/engineer.yaml"
sed -i '/^      - methodologie-/d' "$WORK/capprofile/engineer.yaml"
sed -i '/^spec:/a\  systemPrompt: engineer-role.md' "$WORK/capprofile/engineer.yaml"

cat > "$WORK/run.exs" <<EXS
Process.flag(:trap_exit, true)

# Central fleet_mcp (PodTools http + TaskQueue + ChannelHTTP listener).
Application.put_env(:fleet_mcp, :boot_environment, :host)
Application.put_env(:fleet_mcp, :channel_http_port, 0)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)

{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :u_rc_pod_tools
{:ok, _} = Fleet.MCP.PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
mcp_port = :ranch.get_port(ref)
channel_port = :ranch.get_port(:fleet_mcp_channel_http)

IO.puts("central mcp_port=#{mcp_port} channel_port=#{channel_port}")

# Push la task dans la file centrale — c'est ce que le pod va PULL via get_task.
# Convention POC : task = map libre avec description + nonce pour assert.
:ok = Fleet.MCP.TaskQueue.push(%{
  "ticket_id" => "u-rc-e2e#1",
  "description" => "Ping de santé fleet (gate U-RC). Renvoie via submit_result un payload {status: \"ok\", result: {nonce: \"$NONCE\"}}.",
  "nonce" => "$NONCE"
})

# fleet_spawner avec TmuxBackend + path config-driven.
Application.put_env(:fleet_spawner, :pod_dir_root, "$WORK/pods")
Application.put_env(:fleet_spawner, :state_fs_root, "$WORK/state")
Application.put_env(:fleet_spawner, :launch_backend, Fleet.Spawner.LaunchBackend.TmuxBackend)
# protocole_user_path NON SET → pod.ex utilise priv/sp_drafts/protocole-user-worker.md
# (worker version, yop = trigger workflow ticket-driven).
Application.put_env(:fleet_spawner, :mcp_server_spec, %{
  "command" => "bash",
  "args" => [
    "-c",
    "exec python3 $BINV/fleet_mcp_stdio_bridge.py 2>>$WORK/bridge.log"
  ],
  "env" => %{
    "LCARS_FLEET_MCP_URL" => "http://127.0.0.1:#{mcp_port}/mcp",
    "LCARS_POD_ID" => "$POD_ID"
  }
})
Application.put_env(:fleet_credentials, :creds_root, "$WORK/coffre")
Application.put_env(:fleet_spbuilder, :sp_role_root, "$WORK/sp")
Application.put_env(:fleet_capprofile, :root_dir, "$WORK/capprofile")

{:ok, _} = Application.ensure_all_started(:fleet_spawner)
case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

alias Fleet.EventRouter.Bus
:ok = Bus.subscribe()

{:ok, cap} = Fleet.CapProfile.load("engineer")
pod_id = "$POD_ID"
opts = [
  pod_id: pod_id,
  # Le mandate est encore écrit dans tickets/<ticket_id>.md par pod.ex
  # (visible via Read tool). Mais le canal canonique = TaskQueue centrale
  # (le pod fait get_task tool, pas Read fichier). Le mandate-file est
  # redondant pour le POC mais documente la convention.
  mandate: "Ping de santé fleet (gate U-RC). Voir TaskQueue centrale via get_task.",
  pod_dir_root: "$WORK/pods",
  state_fs_root: "$WORK/state"
]

{:ok, _pod_pid} = Fleet.Spawner.spawn_pod(cap, "u-rc-e2e#1", opts)
IO.puts("run: pod spawné id=#{pod_id} ; attente pod.completed via Bus (≤200s)")

outcome =
  receive do
    {_atom, %{"event_type" => "pod.completed", "payload" => %{"pod_id" => ^pod_id} = p}} ->
      {:completed, p}

    {_atom, %{"event_type" => "pod.failed", "payload" => %{"pod_id" => ^pod_id} = p}} ->
      {:failed, p}
  after
    200_000 -> :timeout
  end

case outcome do
  {:completed, payload} ->
    result = payload["result"] || %{}
    IO.puts("run: pod.completed result=#{inspect(result)}")

    # Extraction nonce : convention SP draft = {status: "ok", result: {nonce: ...}}
    nonce_seen =
      case result do
        %{"status" => "ok", "result" => %{"nonce" => n}} -> n
        %{"nonce" => n} -> n
        _ -> nil
      end

    if nonce_seen == "$NONCE" do
      IO.puts("LLM ATTESTATION OK: nonce match")
      System.halt(0)
    else
      IO.puts("FAIL U-RC: nonce mismatch (got #{inspect(nonce_seen)} ≠ $NONCE)")
      System.halt(1)
    end

  {:failed, payload} ->
    IO.puts("FAIL U-RC: pod.failed payload=#{inspect(payload)}")
    System.halt(1)

  :timeout ->
    IO.puts("FAIL U-RC: timeout 200s — pas de pod.completed/failed via Bus")
    System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/coffre"

echo "== Gate U-RC e2e LLM attestation — TmuxBackend + TaskQueue PULL + submit_result =="
echo "   pod_id=$POD_ID nonce=$NONCE work=$WORK"

cd "$RT" && timeout 240 mix run --no-start "$WORK/run.exs"
RC=$?
echo "---"
if [ "$RC" -ne 0 ]; then
  echo "GATE U-RC : exit $RC (Elixir run)"
  exit "$RC"
fi

# Si on arrive ici avec RC=0, l'attestation LLM est passée. Cleanup tmux.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "  ⚠ tmux session $SESSION encore vivante post-pod.completed (release path?), force kill"
  tmux kill-session -t "$SESSION" 2>/dev/null
fi

echo ""
echo "PASS U-RC e2e : TmuxBackend → tmux + claude REPL → bridge.py + MCP stdio →"
echo "                 yop trigger → SP draft workflow → get_task PULL →"
echo "                 claude exécute → submit_result MCP → Bus pod.result_submitted →"
echo "                 pod.ex extract → pod.completed reçu (nonce $NONCE corrélé)."
echo "GATE U-RC : exit 0"
exit 0
