#!/usr/bin/env bash
# SOURCE: test/gate-face2-git-publish.sh
# AUTHOR: starfleet (consolidation salvage cow-boy)
# STARDATE: 2026.146
# STATUS: salvage v2-functional
# gate-face2-git-publish.sh — Face 2 brique 2.5 e2e : Pipeline → vrai pod claude → submit_result
# (payload {files, message}) → Executor apply_payload → Fleet.Git.publish → commit poussé dans le bare.
#
# exit 0 ssi : la stage déclare `post_extract.git` ; WorkspaceProvisioner clone le bare ; le pod
# claude livre un payload structuré ; Fleet.Git.publish commit+push ; le commit (avec le nonce
# dans son contenu ET sa branche/file `docs/result-NONCE.md`) est présent dans le bare repo distant.
#
# Combine briques 2.1+2.2+2.3+2.4 derrière la chaîne PUSH déjà prouvée par gate-capstone-e2e.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="$(cd "$HERE/.." && pwd)"
BIN="$RT/bin"
ENG_SRC="$RT/apps/fleet_capprofile/priv/canon/cap-profiles/engineer.yaml"
WORK="$(mktemp -d)"
BINV="$(mktemp -d -p /var/tmp lcars-gate-face2.XXXXXX)"
cp "$BIN/bwrap_launch.sh" "$BIN/claude_launch.sh" "$BIN/fleet_mcp_stdio_bridge.py" "$BINV/"
trap 'pkill -f "$WORK" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "KEEP $WORK $BINV" || rm -rf "$WORK" "$BINV"' EXIT

mkdir -p "$WORK/pods" "$WORK/state" "$WORK/coffre/engineer" "$WORK/mirror" \
         "$WORK/sp" "$WORK/capprofile/modop/noop" "$WORK/pipelines" \
         "$WORK/ws-root" "$WORK/bare-seeder"
printf '# Engineer SP base\n' > "$WORK/sp/engineer-role.md"

# --- creds OAuth (depuis host) ---
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

# --- cap-profile test (clone engineer canon + tools MCP fleet + libs vidés + sp pointé) ---
cp "$ENG_SRC" "$WORK/capprofile/engineer.yaml"
sed -i '/^    allowedTools:/a\      - mcp__fleet__get_task\n      - mcp__fleet__submit_result' "$WORK/capprofile/engineer.yaml"
sed -i 's|^    libs:$|    libs: []|' "$WORK/capprofile/engineer.yaml"
sed -i '/^      - methodologie-/d' "$WORK/capprofile/engineer.yaml"
sed -i '/^spec:/a\  systemPrompt: engineer-role.md' "$WORK/capprofile/engineer.yaml"

# --- modop noop (budget) ---
cat > "$WORK/capprofile/modop/noop/profile.yaml" <<'YML'
spec:
  budget:
    maxDurationSec: 150
YML

# --- bare repo source local (file:// accepté par git clone) + 1 commit initial sur main ---
BARE="$WORK/source.git"
git init --bare --initial-branch=main "$BARE" > /dev/null
git init --initial-branch=main "$WORK/bare-seeder" > /dev/null
( cd "$WORK/bare-seeder" \
  && git config user.name seeder \
  && git config user.email seed@lcars.local \
  && echo seed > README.md \
  && git add . > /dev/null \
  && git commit -m "seed" > /dev/null \
  && git remote add origin "$BARE" \
  && git push origin main > /dev/null 2>&1 )

INITIAL_SHA="$(git -C "$BARE" rev-parse main)"
echo "== source bare : $BARE  initial main=$INITIAL_SHA =="

# --- pipeline 1 stage avec post_extract.git (v1 flat — Executor lit pipeline['stages'] direct) ---
cat > "$WORK/pipelines/face2.yaml" <<YML
name: face2
version: 1
stages:
  publish:
    role: engineer
    profile: noop
    post_extract:
      git:
        repo_url: $BARE
        branch: main
        push: true
YML

NONCE="face2-$(date +%s)-$RANDOM"

cat > "$WORK/run.exs" <<EXS
Process.flag(:trap_exit, true)

# --- Central fleet_mcp (PodTools :http + TaskQueue) ---
Application.put_env(:fleet_mcp, :boot_environment, :host)
{:ok, _} = Application.ensure_all_started(:fleet_mcp)
{:ok, _q} = Fleet.MCP.TaskQueue.start_link([])
ref = :face2_srv
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

# --- fleet_pipeline + workspaces_root (face 2 brique 2.4) ---
Application.put_env(:fleet_pipeline, :pipelines_root, "$WORK/pipelines")
Application.put_env(:fleet_pipeline, :workspaces_root, "$WORK/ws-root")
Application.delete_env(:fleet_pipeline, :spawner_backend)

{:ok, _} = Application.ensure_all_started(:fleet_spawner)
{:ok, _} = Application.ensure_all_started(:fleet_pipeline)
case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

alias Fleet.EventRouter.Bus
Bus.subscribe()

# Instruction pour le worker : produire un payload structuré {files, message} via submit_result.
ask = """
Tu vas LIVRER un payload structuré via le tool MCP submit_result.

Le payload doit etre EXACTEMENT cet objet JSON :
{
  "files": [
    {"path": "docs/result-$NONCE.md", "content": "hello from worker $NONCE\\n"}
  ],
  "message": "feat(publish): livraison $NONCE"
}

Appelle submit_result avec ce payload exact (un seul appel). Ne crée aucun fichier toi-meme.
"""

{:ok, pipeline_id} =
  Fleet.Pipeline.start_pipeline("face2", %{ticket_id: "face2#1", ask: ask})

IO.puts("run: pipeline démarré id=#{pipeline_id} ; attente git.published (≤220s)")

outcome =
  receive do
    {_a, %{"event_type" => "git.published", "payload" => %{"pipeline_id" => ^pipeline_id} = p}} ->
      {:published, p}

    {_a, %{"event_type" => "git.publish_failed", "payload" => %{"pipeline_id" => ^pipeline_id} = p}} ->
      {:publish_failed, p}

    {_a, %{"event_type" => "pipeline.failed", "payload" => %{"pipeline_id" => ^pipeline_id} = p}} ->
      {:pipeline_failed, p}
  after
    220_000 -> :timeout
  end

case outcome do
  {:published, payload} ->
    IO.puts("run: git.published payload=#{inspect(payload)}")
    System.halt(0)

  {:publish_failed, payload} ->
    IO.puts("FAIL face2  git.publish_failed payload=#{inspect(payload)}")
    System.halt(1)

  {:pipeline_failed, payload} ->
    IO.puts("FAIL face2  pipeline.failed payload=#{inspect(payload)}")
    System.halt(1)

  :timeout ->
    IO.puts("FAIL face2  timeout (pas de git.published/failed en 220s)")
    System.halt(1)
end
EXS

export LCARS_CREDS_ROOT="$WORK/coffre" LCARS_GIT_MIRROR="$WORK/mirror" LCARS_BWRAP_NO_CLEANUP=1
echo "== Gate FACE 2 brique 2.5 — Pipeline → pod claude → submit_result(files,message) → Fleet.Git.publish → bare =="
echo "   nonce : $NONCE"
cd "$RT" && timeout 280 mix run --no-start "$WORK/run.exs"
RC=$?
echo "---"
if [ "$RC" -ne 0 ]; then
  echo "GATE FACE 2 : exit $RC (Elixir run)"
  exit "$RC"
fi

# Vérification post-run : le bare repo distant a-t-il reçu le commit ?
FINAL_SHA="$(git -C "$BARE" rev-parse main)"
echo "== source bare : main initial=$INITIAL_SHA final=$FINAL_SHA =="

if [ "$FINAL_SHA" = "$INITIAL_SHA" ]; then
  echo "FAIL face2  HEAD du bare inchangé — aucun push reçu"
  exit 1
fi

# Le commit contient-il bien le file livré + le nonce ?
if ! git -C "$BARE" show --name-only --format= main | grep -q "docs/result-$NONCE.md"; then
  echo "FAIL face2  fichier 'docs/result-$NONCE.md' absent du commit HEAD"
  exit 1
fi

if ! git -C "$BARE" show main -- "docs/result-$NONCE.md" | grep -q "hello from worker $NONCE"; then
  echo "FAIL face2  contenu attendu absent du fichier livré"
  exit 1
fi

# L'auteur du commit reflète-t-il le worker (D-04) ?
AUTHOR="$(git -C "$BARE" log -1 --format='%an <%ae>' main)"
COMMITTER="$(git -C "$BARE" log -1 --format='%cn <%ce>' main)"
echo "== commit author='$AUTHOR' committer='$COMMITTER' =="

if [ "$AUTHOR" != "engineer <engineer@lcars.local>" ]; then
  echo "FAIL face2  author attendu 'engineer <engineer@lcars.local>' — got '$AUTHOR'"
  exit 1
fi

if [ "$COMMITTER" != "LCARS System <system@lcars.local>" ]; then
  echo "FAIL face2  committer attendu 'LCARS System <system@lcars.local>' — got '$COMMITTER'"
  exit 1
fi

echo "PASS face2  Pipeline → pod claude → submit_result(files,message) → Fleet.Git.publish → push bare ok"
echo "            chaîne PUSH système-side complète prouvée e2e ; D-04 (author≠committer) respectée"
echo "GATE FACE 2 : exit 0"
exit 0
