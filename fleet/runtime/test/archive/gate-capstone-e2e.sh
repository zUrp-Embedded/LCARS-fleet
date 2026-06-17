#!/usr/bin/env bash
# SOURCE: test/gate-capstone-e2e.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-capstone-e2e.sh — WALKING SKELETON : le 1er thread e2e COMPLET du runtime v2 (modèle PUSH).
# exit 0 ssi : `Fleet.Pipeline.start_pipeline` (1 stage) → Executor → StageRunner → SpawnerBackend.Default
# (build_mandate) → `Fleet.Spawner.spawn_pod` → vrai pod claude (bwrap+PortBackend) → brief porte la
# tâche → le pod spawne le pont stdio → fleet_mcp central HTTP → `submit_result` → Bus
# `pod.result_submitted` → pod.ex (souscrit) → `pod.completed{result}` → Executor avance → `pipeline.completed`.
# PREUVE : `pipeline.completed{pipeline_id}` reçu sur le Bus ET le nonce (passé en mandate, renvoyé par le
# pod) présent dans `payload.outputs`. Combine gate-2.2 (pod↔central) + R1.3 (completion→Pipeline) via le
# VRAI Pipeline (pas de stub). Aucune décision archi : assemble des bricks déjà verts.
# Bin+pont+launchers hors /home,/tmp (bwrap tmpfs).
set -uo pipefail

# ── SUPERSEDED (Fable F168-F178) — archi coffre + file MCP-channel globale RETIRÉE ──
# Cette gate e2e teste un modèle DISPARU : coffre credentials (pré-ADR-F : on bind le claudeDir
# natif), file globale Fleet.MCP.TaskQueue.push/results (pré-per-pod Fleet.TaskQueue), listener
# channel HTTP (purgé ADR-G C5.1). Réécriture contre l'archi courante (per-pod + bwrap/RC) = exige
# un vrai claude+bwrap → chantier deploy-env, non faisable en sandbox. Round-trip MCP per-pod prouvé
# par gate-r4-mcp-boot.sh (réécrit + validé). Corps historique conservé ci-dessous (archive).
echo "SUPERSEDED — gate e2e archi coffre/MCP-channel (pré-ADR-F/ADR-G). Réécriture = deploy-env. cf. gate-r4-mcp-boot.sh"
exit 2
HERE="$(cd "$(dirname "$0")" && pwd)"; RT="$(cd "$HERE/.." && pwd)"; BIN="$RT/bin"
ENG_SRC="$RT/apps/fleet_capprofile/priv/canon/cap-profiles/engineer.yaml"
WORK="$(mktemp -d)"
BINV="$(mktemp -d -p /var/tmp lcars-gate-capstone.XXXXXX)"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BIN/fleet_mcp_stdio_bridge.py" "$BINV/"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT
mkdir -p "$WORK/pods" "$WORK/state" "$WORK/coffre/engineer" "$WORK/mirror" "$WORK/sp" \
         "$WORK/capprofile/modop/noop" "$WORK/pipelines"
printf '# Engineer SP base\n' > "$WORK/sp/engineer-role.md"

# --- creds (coffre engineer, depuis les creds OAuth host) ---
python3 - "$WORK/coffre/engineer" <<'PY'
import json, sys, os
d = json.load(open('/home/starfleet/.claude/.credentials.json'))['claudeAiOauth']
b = sys.argv[1]
# Vulcan #6 : single-file coffre.json (atomicité garantie).
coffre = {
    'refresh_token': d['refreshToken'],
    'access_token': d['accessToken'],
    'scopes': ' '.join(d.get('scopes', [])),
    'expires_at': d.get('expiresAt', 9999999999999),
}
open(os.path.join(b, 'coffre.json'), 'w').write(json.dumps(coffre, indent=2))
PY

# --- cap-profile de TEST : clone engineer.yaml réel, ajoute les tools MCP fleet (auto-approuvés),
#     vide les libs (pas de fichier lib à résoudre), ajoute systemPrompt → le SP base existant. ---
cp "$ENG_SRC" "$WORK/capprofile/engineer.yaml"
sed -i '/^    allowedTools:/a\      - mcp__fleet__get_task\n      - mcp__fleet__submit_result' "$WORK/capprofile/engineer.yaml"
sed -i 's|^    libs:$|    libs: []|' "$WORK/capprofile/engineer.yaml"
sed -i '/^      - methodologie-/d' "$WORK/capprofile/engineer.yaml"
sed -i '/^spec:/a\  systemPrompt: engineer-role.md' "$WORK/capprofile/engineer.yaml"

# --- modop noop : override inoffensif (budget), zéro clé réservée → schema-valide, deep-merge clean ---
cat > "$WORK/capprofile/modop/noop/profile.yaml" <<'YML'
# modop noop (capstone) — override budget, aucune clé réservée (apiVersion/kind/metadata.*)
spec:
  budget:
    maxDurationSec: 150
YML

# --- pipeline 1 stage (schema v1 : role+profile requis) ---
cat > "$WORK/pipelines/capstone.yaml" <<'YML'
name: capstone
version: 1
stages:
  only_stage:
    role: engineer
    profile: noop
YML

NONCE="capstone-$(date +%s)-$RANDOM"

cat > "$WORK/run.exs" <<EXS
Process.flag(:trap_exit, true)

# --- Central fleet_mcp (PodTools :http + TaskQueue) — host-side, état partagé ---
Application.put_env(:fleet_mcp, :boot_environment, :host)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)
{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :capstone_srv
{:ok, _http} = Fleet.MCP.PodTools.start_link(transport: :http, port: 0, ranch_ref: ref)
mcp_port = :ranch.get_port(ref)

# --- fleet_spawner (vrai pod) ---
Application.put_env(:fleet_spawner, :pod_dir_root, "$WORK/pods")
Application.put_env(:fleet_spawner, :state_fs_root, "$WORK/state")
Application.put_env(:fleet_spawner, :launch_backend, Fleet.Spawner.LaunchBackend.PortBackend)
Application.put_env(:fleet_spawner, :bwrap_launch_path, "$BINV/bwrap_launch.sh")
Application.put_env(:fleet_spawner, :claude_launch_path, "$BINV/claude_launch.sh")
Application.put_env(:fleet_spawner, :mcp_server_spec, %{
  "command" => "python3",
  "args" => ["$BINV/fleet_mcp_stdio_bridge.py"],
  "env" => %{"LCARS_FLEET_MCP_URL" => "http://localhost:#{mcp_port}/mcp"}
})
Application.put_env(:fleet_credentials, :creds_root, "$WORK/coffre")
Application.put_env(:fleet_spbuilder, :sp_role_root, "$WORK/sp")
Application.put_env(:fleet_capprofile, :root_dir, "$WORK/capprofile")

# --- fleet_pipeline (vrai Pipeline → Default backend, PAS de stub) ---
Application.put_env(:fleet_pipeline, :pipelines_root, "$WORK/pipelines")
Application.delete_env(:fleet_pipeline, :spawner_backend)

{:ok, _} = Application.ensure_all_started(:fleet_spawner)
{:ok, _} = Application.ensure_all_started(:fleet_pipeline)
case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

alias Fleet.EventRouter.Bus
Bus.subscribe()

# Le travail (nonce) est PUSH via le mandate_context → build_mandate → brief du pod.
{:ok, pipeline_id} =
  Fleet.Pipeline.start_pipeline("capstone", %{
    ticket_id: "capstone#1",
    ask: "Reponds EXACTEMENT et UNIQUEMENT le mot suivant, rien d'autre : $NONCE"
  })

IO.puts("run: pipeline démarré id=#{pipeline_id} ; attente pipeline.completed (≤200s)")

outcome =
  receive do
    {_a, %{"event_type" => "pipeline.completed", "payload" => %{"pipeline_id" => ^pipeline_id} = p}} ->
      {:completed, p}
    {_a, %{"event_type" => "pipeline.failed", "payload" => %{"pipeline_id" => ^pipeline_id} = p}} ->
      {:failed, p}
  after
    200_000 -> :timeout
  end

case outcome do
  {:completed, payload} ->
    outputs = payload["outputs"] || %{}
    hit? = String.contains?(inspect(outputs), "$NONCE")
    IO.puts("run: pipeline.completed outputs=#{inspect(outputs)}")
    if hit? do
      IO.puts("PASS capstone  Pipeline.start_pipeline → vrai pod → submit_result → pod.completed → pipeline.completed")
      IO.puts("              nonce (push via mandate) présent dans outputs = chaîne PUSH complète prouvée e2e")
      System.halt(0)
    else
      IO.puts("FAIL capstone  pipeline.completed mais nonce absent des outputs")
      System.halt(1)
    end

  {:failed, payload} ->
    IO.puts("FAIL capstone  pipeline.failed payload=#{inspect(payload)}")
    System.halt(1)

  :timeout ->
    IO.puts("FAIL capstone  timeout (pas de pipeline.completed/failed en 200s)")
    System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/coffre" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate CAPSTONE e2e — walking skeleton : Pipeline → vrai pod → result MCP → pipeline.completed =="
echo "   nonce (push via mandate_context, renvoyé par le pod) : $NONCE"
cd "$RT" && timeout 260 mix run --no-start "$WORK/run.exs"
RC=$?
echo "---"
if [ "$RC" -eq 0 ]; then
  echo "GATE CAPSTONE : exit 0 — 1er thread e2e COMPLET (chaîne push Pipeline→pod→completed)"
else
  echo "GATE CAPSTONE : exit $RC"
fi
exit "$RC"
