#!/usr/bin/env bats
# SOURCE: .claude/skills/state_of_the_fleet/tests/probes.bats
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — le gate de l'instrument de mesure
#
# These test the probes' CONTRACT, never the fleet's state: the state varies by definition, the
# contract must not. A diagnostic toolkit that is itself unmeasured is the thing this toolkit exists
# to object to — and the need is not theoretical: a self-referential `grep` symlink in a throwaway
# harness already made one probe blind, and only its refusal to conclude kept it honest.

setup() {
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROBES="$SKILL_DIR/probes"
  # shellcheck source=../probes/lib.sh
  . "$PROBES/lib.sh"
  sotf_init
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

# ── The output contract ───────────────────────────────────────────────────────────────────────────

@test "emit produit un JSON valide portant les 8 champs du contrat" {
  run emit "x.y" "fleet" "operational" "local" "cmd" "ev" "limite"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    has("probe") and has("plane") and has("verdict") and has("vantage")
    and has("method") and has("evidence") and has("cannot_conclude") and has("ts")' >/dev/null
}

@test "emit encode une evidence qui contient guillemets, retour ligne et UTF-8 sans casser le JSON" {
  # Evidence is verbatim BY CONTRACT, and verbatim means untrusted as a string: a probe quoting a
  # server's error body must not be able to break the format of the report that quotes it.
  run emit "x.y" "fleet" "degraded" "local" "cmd" 'il a dit "non" \ et
puis rien — 404' "limite"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.evidence | contains("non")' >/dev/null
}

@test "emit refuse un cannot_conclude vide : le champ est obligatoire" {
  run emit "x.y" "fleet" "operational" "local" "cmd" "ev" ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "contrat viole"
  # It still emits — a broken probe must not silence the whole run — but never with an empty limit,
  # which would read as "this proves everything".
  echo "$output" | grep -v "contrat viole" | jq -e '.cannot_conclude | length > 0' >/dev/null
}

@test "emit signale un verdict hors vocabulaire au lieu de le laisser passer" {
  run emit "x.y" "fleet" "vert-ish" "local" "cmd" "ev" "limite"
  echo "$output" | grep -q "verdict invalide"
}

# ── Verdict tallies and exit code ─────────────────────────────────────────────────────────────────

@test "erreur-de-sonde l'emporte sur drift : un run aveugle est pire qu'un run qui a trouve" {
  # A run that could not measure is worse than one that measured a problem, because its silence
  # looks like health.
  SOTF_OK=1 SOTF_DRIFT=1 SOTF_ERROR=1 SOTF_UNKNOWN=0
  [ "$(sotf_exit_code)" -eq 2 ]
}

@test "drift seul rend 1, tout-vert rend 0" {
  SOTF_OK=3 SOTF_DRIFT=1 SOTF_ERROR=0 SOTF_UNKNOWN=0
  [ "$(sotf_exit_code)" -eq 1 ]
  SOTF_OK=3 SOTF_DRIFT=0 SOTF_ERROR=0 SOTF_UNKNOWN=0
  [ "$(sotf_exit_code)" -eq 0 ]
}

@test "unknown seul ne fait PAS echouer le run : une ambiguite DECLAREE est un resultat honnete" {
  SOTF_OK=2 SOTF_DRIFT=0 SOTF_ERROR=0 SOTF_UNKNOWN=3
  [ "$(sotf_exit_code)" -eq 0 ]
}

@test "inactive compte comme conforme : eteint delibere n'est pas une faute" {
  SOTF_OK=0 SOTF_DRIFT=0 SOTF_ERROR=0 SOTF_UNKNOWN=0
  emit "x.y" "fleet" "inactive" "local" "cmd" "ev" "limite" >/dev/null
  [ "$SOTF_OK" -eq 1 ]
  [ "$(sotf_exit_code)" -eq 0 ]
}

# ── Port derivation ───────────────────────────────────────────────────────────────────────────────

@test "url : trois sources, dans cet ordre — env > fichier de la fleet > derivation uid" {
  # Each branch is isolated with LCARS_RUN_DIR, otherwise the test measures whatever the DEVELOPER's
  # box happens to have — which is exactly the "the machine is not the reference" trap.
  local expected=$(( 21000 + ($(id -u) % 500) * 10 ))

  # 3. derivation : ni env, ni fichier
  run env -u LCARS_API_URL -u LCARS_OBS_URL LCARS_RUN_DIR="$TMP/vide" bash -c \
    '. '"$PROBES"'/lib.sh; echo "$(sotf_api_url)|$(sotf_obs_url)|$(sotf_url_origin)"'
  [[ "$output" == "http://127.0.0.1:$expected|"* ]]
  [[ "$output" == *"|http://127.0.0.1:$(( expected + 1 ))|"* ]]
  [[ "$output" == *"|derive de"*"$(id -u)" ]]

  # 2. le fichier que `bin/fleet_v2` ecrit lui-meme — il bat la derivation, parce qu'il est la
  #    reponse de la fleet a "ou j'ecoute" et non une hypothese sur l'uid du lecteur.
  mkdir -p "$TMP/run"; echo "http://ailleurs:9990" > "$TMP/run/api_url"
  run env -u LCARS_API_URL -u LCARS_OBS_URL LCARS_RUN_DIR="$TMP/run" bash -c \
    '. '"$PROBES"'/lib.sh; echo "$(sotf_api_url)|$(sotf_obs_url)|$(sotf_url_origin)"'
  [[ "$output" == "http://ailleurs:9990|http://ailleurs:9991|annonce par la fleet"* ]]

  # 1. l'env de l'operateur bat tout
  run env LCARS_API_URL="http://explicite:1234/" LCARS_RUN_DIR="$TMP/run" bash -c \
    '. '"$PROBES"'/lib.sh; echo "$(sotf_api_url)|$(sotf_url_origin)"'
  [[ "$output" == "http://explicite:1234|env" ]]
}

@test "la garde « rien a atteindre » : pas de run dir → inactive, jamais degraded ni unreachable" {
  # THE rule the two specimens forced into existence, and the reason it lives in lib.sh: it was
  # hand-copied into three probes and produced three DIFFERENT verdicts for one situation.
  run env LCARS_RUN_DIR="$TMP/vide" bash -c \
    '. '"$PROBES"'/lib.sh; sotf_init; sotf_skip_no_fleet x.y fleet "sans objet" && echo "SKIP=oui"'
  echo "$output" | grep -q "SKIP=oui"
  # La sortie melange la ligne JSON et le marqueur du test : on isole la ligne JSON avant jq,
  # sinon jq echoue sur la ligne de texte et le test rougit pour la mauvaise raison.
  echo "$output" | grep '^{' | jq -e 'select(.probe=="x.y") | .verdict=="inactive"' >/dev/null

  mkdir -p "$TMP/run2"
  run env LCARS_RUN_DIR="$TMP/run2" bash -c \
    '. '"$PROBES"'/lib.sh; sotf_init; sotf_skip_no_fleet x.y fleet || echo "PROCEDE=oui"'
  echo "$output" | grep -q "PROCEDE=oui"
}

# ── The git guarantee ─────────────────────────────────────────────────────────────────────────────

@test "git_ro passe TOUJOURS --no-optional-locks (garantie anti-course avec WorktreeSync)" {
  # THE regression not to allow. `/home/projects/<name>` is driven by a GenServer that exists solely
  # to serialise `git reset --hard`; a probe taking `index.lock` would be a diagnostic tool causing
  # the incident it reports. Asserted on the real invocation, not on the source.
  local fake="$TMP/bin"; mkdir -p "$fake"
  cat > "$fake/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
  chmod +x "$fake/git"
  run env PATH="$fake:$PATH" bash -c '. '"$PROBES"'/lib.sh; git_ro /tmp status'
  echo "$output" | grep -qx -- "--no-optional-locks"
  echo "$output" | grep -qx -- "core.fsmonitor="
}

@test "aucune sonde n'appelle git en dehors de git_ro" {
  # A single bare `git` call reopens the race. Scoped to the NUMBERED probes: `lib.sh` is where the
  # wrapper is defined, so it is the one file legitimately holding a bare `git`.
  run bash -c "grep -nE '(^|[;|&]|[\$]\\()[[:space:]]*git[[:space:]]' $PROBES/[0-9]*.sh | grep -v git_ro"
  [ -z "$output" ]
}

# ── trim ──────────────────────────────────────────────────────────────────────────────────────────

@test "trim MARQUE la troncature : un lecteur ne doit jamais prendre un extrait pour le tout" {
  run trim "$(printf 'a%.0s' {1..50})" 10
  [[ "$output" == *"tronque a 10 car."* ]]
  run trim "court" 10
  [ "$output" = "court" ]
}

# ── http_probe : mesure impossible vs mesure ratee ────────────────────────────────────────────────

@test "http_probe rend 1 quand curl est absent (aveugle), 0 quand curl a tourne et echoue (mesure)" {
  # The distinction that separates `unreachable` from `degraded`, asserted at its source.
  # The fake PATH keeps a shell (without it the harness dies at 127 and proves nothing) but no curl.
  local fake="$TMP/nobin"; mkdir -p "$fake"
  ln -sf "$(command -v bash)" "$fake/bash"
  run env PATH="$fake" bash -c '. '"$PROBES"'/lib.sh; http_probe http://127.0.0.1:1/x'
  [ "$status" -eq 1 ]

  run bash -c '. '"$PROBES"'/lib.sh; http_probe "http://127.0.0.1:1/x" 2; echo "rc=$? code=$SOTF_HTTP_CODE"'
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"code=000"* ]]
}

# ── 10-instruments, bout en bout ──────────────────────────────────────────────────────────────────

@test "10-instruments emet du JSON valide sur toutes ses lignes" {
  run "$PROBES/10-instruments.sh"
  [ -n "$output" ]
  while IFS= read -r line; do
    echo "$line" | jq -e 'has("probe") and has("cannot_conclude")' >/dev/null
  done <<< "$output"
}

@test "hors pod, les sondes de pod disent inactive — pas degraded (zero fausse alarme)" {
  run bash -c 'unset LCARS_POD_ID; '"$PROBES"'/10-instruments.sh 2>/dev/null'
  echo "$output" | jq -e 'select(.probe=="instruments.mcp_socket") | .verdict=="inactive"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="instruments.mcp_bridge") | .verdict=="inactive"' >/dev/null
}

@test "un outil requis absent : degraded sur l'inventaire, unreachable sur ce qui en dependait" {
  # One missing tool, TWO verdicts, both correct. Conflating them reports a live fleet as dead, or a
  # dead one as unmeasured.
  local fake="$TMP/bin2"; mkdir -p "$fake"
  for t in bash dirname basename date id tr grep head cat jq git; do
    for d in /usr/bin /bin; do [ -x "$d/$t" ] && { ln -sf "$d/$t" "$fake/$t"; break; }; done
  done
  run env PATH="$fake" "$PROBES/10-instruments.sh"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e 'select(.probe=="instruments.shell_tools") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="instruments.endpoint_api") | .verdict=="unreachable"' >/dev/null
}

@test "bridge MCP : un interpreteur declare mais absent est nomme (le cas A-1)" {
  # The failure that cost a live starfleet an eight-hour session to establish by hand.
  local home="$TMP/pod"; mkdir -p "$home"
  cat > "$home/.mcp-fleet.json" <<'JSON'
{"mcpServers":{"fleet":{"command":"bash","args":["-c","exec pythonXX /x/bridge.py"]}}}
JSON
  run env LCARS_POD_ID=p1 LCARS_ROLE=starfleet LCARS_POD_HOME="$home" "$PROBES/10-instruments.sh"
  echo "$output" | jq -e 'select(.probe=="instruments.mcp_bridge") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="instruments.mcp_bridge") | .evidence | contains("pythonXX")' >/dev/null
}

@test "bridge MCP : une declaration illisible rend unknown, jamais un faux vert" {
  local home="$TMP/pod2"; mkdir -p "$home"
  echo '{"mcpServers":{}}' > "$home/.mcp-fleet.json"
  run env LCARS_POD_ID=p1 LCARS_POD_HOME="$home" "$PROBES/10-instruments.sh"
  echo "$output" | jq -e 'select(.probe=="instruments.mcp_bridge") | .verdict=="unknown"' >/dev/null
}

# ── render.sh : le rendu ne doit jamais inventer ni masquer ───────────────────────────────────────
# The JSONL stays the source of truth; these pin that presenting it cannot lose a verdict.

fixture() {
  cat <<'JSONL'
{"probe":"instruments.context","plane":"instruments","verdict":"operational","vantage":"local","method":"m1","evidence":"hote","cannot_conclude":"limite-A","ts":"2026-01-01T00:00:00Z"}
{"probe":"fleet.health","plane":"fleet","verdict":"degraded","vantage":"hote-http","method":"m2","evidence":"HTTP 500","cannot_conclude":"limite-B","ts":"2026-01-01T00:00:01Z"}
{"probe":"fleet.build","plane":"fleet","verdict":"unreachable","vantage":"hote-http","method":"m3","evidence":"curl absent","cannot_conclude":"limite-C","ts":"2026-01-01T00:00:02Z"}
JSONL
}

@test "render terminal : une ligne par sonde, groupee par plan" {
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh"
  echo "$output" | grep -q "\[instruments\]"
  echo "$output" | grep -q "\[fleet\]"
  [ "$(echo "$output" | grep -cE 'instruments\.context|fleet\.health|fleet\.build')" -eq 3 ]
}

@test "render terminal : la limite est cachee sur un OK, montree des que ce n'est plus vert" {
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh"
  ! echo "$output" | grep -q "limite-A"
  echo "$output" | grep -q "limite-B"
  echo "$output" | grep -q "limite-C"
}

@test "render terminal --full : toutes les limites, y compris sur les verts" {
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh --full"
  echo "$output" | grep -q "limite-A"
}

@test "render markdown : TOUTES les limites, toujours — un rapport archive sans elles ment" {
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh --md"
  echo "$output" | grep -q "limite-A"
  echo "$output" | grep -q "limite-B"
  echo "$output" | grep -q "ne prouve pas"
}

@test "verdict global : aveugle l'emporte sur drift, et le code de sortie suit" {
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh --md"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "AVEUGLE"

  run bash -c "$(declare -f fixture); fixture | grep -v unreachable | $PROBES/render.sh --md"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "DEGRADE"

  run bash -c "$(declare -f fixture); fixture | grep operational | $PROBES/render.sh --md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CONFORME"
}

@test "render : une ligne non-JSON est CONSERVEE, jamais avalee" {
  run bash -c "$(declare -f fixture); { fixture; printf 'sonde.x\tdegraded\tlocal\tbrut\tlimite\n'; } | $PROBES/render.sh --md"
  echo "$output" | grep -q "lignes non-JSON"
  echo "$output" | grep -q "sonde.x"
}

@test "render : entree vide = erreur, pas un rapport vert" {
  run bash -c ": | $PROBES/render.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "aucune sonde"
}

@test "render --out ecrit le fichier et le signale" {
  local f="$TMP/rapport.md"
  run bash -c "$(declare -f fixture); fixture | $PROBES/render.sh --out '$f'"
  [ -s "$f" ]
  grep -q "Etat de la fleet" "$f"
}

@test "deux rendus du meme JSONL sont identiques (repetable)" {
  run bash -c "$(declare -f fixture); diff <(fixture | $PROBES/render.sh --md) <(fixture | $PROBES/render.sh --md)"
  [ -z "$output" ]
}

# ── 30-pods / 40-forge : sondes HTTP, testees contre un serveur bouchon ───────────────────────────
# Hermetic on purpose: the gate must be green on a box with no fleet and no forge. A stub answering
# chosen codes exercises the REAL curl path — stubbing `http_probe` would test the harness instead.

stub_server() {
  local dir="$1" port
  python3 - "$dir" <<'PY' &
import http.server, socketserver, sys, os, json, threading
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        route = self.path.split('?')[0]
        f = os.path.join(d, route.strip('/').replace('/', '_') or 'root')
        if os.path.exists(f):
            code, body = open(f).read().split('\n', 1)
            self.send_response(int(code)); self.end_headers(); self.wfile.write(body.encode())
        else:
            self.send_response(404); self.end_headers(); self.wfile.write(b'{"message":"nope"}')
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    open(os.path.join(d, ".port"), "w").write(str(s.server_address[1]))
    s.serve_forever()
PY
  STUB_PID=$!
  for _ in $(seq 1 50); do [ -s "$dir/.port" ] && break; sleep 0.05; done
  STUB_PORT="$(cat "$dir/.port" 2>/dev/null)"
}
stub_stop() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; }

@test "30-pods : un 501 sur le port API est le CONTRAT, pas une panne" {
  local d="$TMP/stub"; mkdir -p "$d"
  printf '501\nnot implemented' > "$d/api_pods"
  printf '200\n{"pods":[]}'     > "$d/api_pods_obs"
  stub_server "$d"
  run env LCARS_API_URL="http://127.0.0.1:$STUB_PORT" LCARS_OBS_URL="http://127.0.0.1:$STUB_PORT" \
    "$PROBES/30-pods.sh"
  stub_stop
  echo "$output" | jq -e 'select(.probe=="pods.port_guard") | .verdict=="operational"' >/dev/null
}

@test "30-pods : si le port API se met a SERVIR des pods, le changement de contrat est signale" {
  # The day the runtime changes, this line changes with it — instead of a probe silently reading the
  # wrong surface as the reference list.
  local d="$TMP/stub2"; mkdir -p "$d"
  printf '200\n{"pods":[]}' > "$d/api_pods"
  stub_server "$d"
  run env LCARS_API_URL="http://127.0.0.1:$STUB_PORT" LCARS_OBS_URL="http://127.0.0.1:$STUB_PORT" \
    "$PROBES/30-pods.sh"
  stub_stop
  echo "$output" | jq -e 'select(.probe=="pods.port_guard") | .verdict=="degraded"' >/dev/null
}

@test "30-pods : zero pod est un etat legitime, jamais un drift" {
  # An idle fleet must not be permanently red.
  local d="$TMP/stub3"; mkdir -p "$d"
  printf '501\nx'           > "$d/api_pods"
  printf '200\n{"total":0}' > "$d/api_projection"
  stub_server "$d"
  run env LCARS_API_URL="http://127.0.0.1:$STUB_PORT" LCARS_OBS_URL="http://127.0.0.1:$STUB_PORT" \
    "$PROBES/30-pods.sh"
  stub_stop
  # `/api/pods` on the obs side is absent from the stub → 404 → degraded, never a silent "0 pod".
  ! echo "$output" | jq -e 'select(.probe=="pods.live") | .evidence | contains("0 pod")' >/dev/null
}

@test "40-forge : sans FORGE_BASE_URL c'est inactive — rien de declare n'est pas un angle mort" {
  # Corrige apres mesure : `unreachable` faisait basculer tout le rapport en AVEUGLE sur une boite
  # saine dont personne n'avait configure de forge. Mon instrument n'est pas casse, il n'y a
  # simplement rien a atteindre. Et `degraded` serait pire : une affirmation sur une forge jamais
  # contactee.
  run env -u FORGE_BASE_URL "$PROBES/40-forge.sh"
  echo "$output" | jq -e 'select(.probe=="forge.configured") | .verdict=="inactive"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="forge.org") | .verdict=="inactive"' >/dev/null
  # et le run ne doit PAS etre rouge pour ca
  [ "$status" -eq 0 ]
}

@test "40-forge : un 404 anonyme sur une org DECLAREE rend unknown, avec ses DEUX lectures" {
  # THE case the manual report caught by discipline: absent vs invisible-without-auth.
  #
  # `FORGE_ORG` est POSE ici, et ce n'etait pas le cas avant : le meme commit qui a supprime le nom
  # devine a laisse ce test asserter le contrat qu'il venait de remplacer. Une suite verte est une
  # affirmation — celle-ci etait rouge pendant que j'affirmais le contraire. Sans org declaree, la
  # sonde s'abstient desormais (`inactive`), et c'est le test voisin qui le verrouille ; l'ambiguite
  # du 404 ne se mesure que sur une org qu'on a effectivement le droit de chercher.
  local d="$TMP/stub4"; mkdir -p "$d"
  printf '200\n{"version":"1.26.4"}' > "$d/api_v1_version"
  stub_server "$d"
  run env FORGE_BASE_URL="http://127.0.0.1:$STUB_PORT" FORGE_ORG=fleet LCARS_HUMAN=someone "$PROBES/40-forge.sh"
  stub_stop
  echo "$output" | jq -e 'select(.probe=="forge.org") | .verdict=="unknown"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="forge.org") | .cannot_conclude | contains("invisible")' >/dev/null
}

@test "40-forge : un service qui repond sans etre une forge est degraded, pas operational" {
  local d="$TMP/stub5"; mkdir -p "$d"
  stub_server "$d"   # rien de servi → 404 partout, y compris /api/v1/version
  run env FORGE_BASE_URL="http://127.0.0.1:$STUB_PORT" "$PROBES/40-forge.sh"
  stub_stop
  echo "$output" | jq -e 'select(.probe=="forge.reachable") | .verdict=="degraded"' >/dev/null
}

@test "40-forge : aucun credential dans un pod est ATTENDU (inactive), pas une faute" {
  run env -u FORGE_TOKEN_FILE -u FORGE_ROLE_TOKENS_DIR HOME="$TMP" "$PROBES/40-forge.sh"
  echo "$output" | jq -e 'select(.probe=="forge.credentials") | .verdict=="inactive"' >/dev/null
}

# ── 60-self : les liaisons declare↔observe ───────────────────────────────────────────────────────

@test "60-self : sans cap-profile, inactive — rien a confronter n'est pas une faute" {
  run env -u LCARS_POD_ID LCARS_POD_HOME="$TMP/vide" "$PROBES/60-self.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'select(.probe=="self.cap_profile") | .verdict=="inactive"' >/dev/null
}

@test "60-self : une divergence cap-profile ↔ launcher est NOMMEE des deux cotes" {
  # Le format de `claude_launch.dbg` est MESURE (`allowed='a,b,c'`), pas suppose : la premiere
  # version cherchait `--allowedTools`, une forme inventee, et rendait `unknown` sur une trace
  # parfaitement lisible.
  local h="$TMP/pod"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"probe","containment":"bwrap"},
 "spec":{"scope":{"allowedTools":["Read","Bash"]},"knowledge":{"skills":[]}}}
JSON
  echo "[00:00:00] step jq tools OK allowed='Read,Bash,mcp__fleet__submit_result' disallowed='x'" > "$h/claude_launch.dbg"
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  echo "$output" | jq -e 'select(.probe=="self.tools") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="self.tools") | .evidence | contains("submit_result")' >/dev/null
}

@test "60-self : listes identiques → operational, sans reparer quoi que ce soit" {
  local h="$TMP/pod2"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"p","containment":"bwrap"},
 "spec":{"scope":{"allowedTools":["Read","Bash"]}}}
JSON
  echo "step jq tools OK allowed='Read,Bash' disallowed='x'" > "$h/claude_launch.dbg"
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  echo "$output" | jq -e 'select(.probe=="self.tools") | .verdict=="operational"' >/dev/null
}

@test "60-self : un champ tableau est APLATI, pas rendu en JSON brut" {
  # `flatten` est load-bearing : `.spec.knowledge.skills` EST un tableau, donc `[...]` donnait un
  # tableau de tableau et l'evidence affichait `["a" "b"]` au lieu des elements.
  local h="$TMP/pod3"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"p"},
 "spec":{"knowledge":{"skills":["alpha","beta"]}}}
JSON
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  echo "$output" | jq -e 'select(.probe=="self.skills") | .evidence | contains("alpha beta")' >/dev/null
  ! echo "$output" | jq -e 'select(.probe=="self.skills") | .evidence | contains("[")' >/dev/null
}

@test "60-self : ce qui n'est observable QUE de l'interieur dit unreachable, jamais operational" {
  # Inspecter un pod par son repertoire donne les fichiers, pas le noyau. Confondre les deux ferait
  # rendre un verdict sur des mounts et des capabilities qui sont ceux de l'HOTE.
  local h="$TMP/pod4"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"p","containment":"bwrap",
 "mounts":[{"path":"/home/projects","mode":"rw"}]},"spec":{"invocation":{"effort":"high"}}}
JSON
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  for p in self.mounts self.containment self.effort; do
    echo "$output" | jq -e "select(.probe==\"$p\") | .verdict==\"unreachable\"" >/dev/null
  done
}

@test "60-self : la couverture avoue son perimetre au lieu de le taire" {
  # Un champ non couvert n'est pas conforme — il n'est pas regarde. Et le compteur doit etre JUSTE :
  # `cut -d'¤'` echouait (separateur multi-octets) et annonçait 1 champ lie sur 27.
  local h="$TMP/pod5"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"p","containment":"bwrap","role_index":3},
 "spec":{"brief_kind":"worker","scope":{"allowedTools":["Read"]}}}
JSON
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  echo "$output" | jq -e 'select(.probe=="self.coverage") | .verdict=="unknown"' >/dev/null
  # les champs sans liaison sont NOMMES
  echo "$output" | jq -e 'select(.probe=="self.coverage") | .evidence | contains("spec.brief_kind")' >/dev/null
  # et le compteur n'est pas 1
  ! echo "$output" | jq -e 'select(.probe=="self.coverage") | .evidence | startswith("1/")' >/dev/null
}

@test "40-forge : sans nom d'org declare, on ne DEVINE pas — et le compte humain reste teste" {
  # Deux fautes en une, corrigees ensemble. `FORGE_ORG` n'existe nulle part : la premiere version
  # testait `${FORGE_ORG:-fleet}`, nom de variable ET valeur inventes. Puis le correctif a couple
  # deux questions independantes par un `return` : ne pas connaitre l'org faisait sauter la
  # verification du compte, qui n'en depend pas.
  local d="$TMP/stub6"; mkdir -p "$d"
  printf '200\n{"version":"1.26.4"}' > "$d/api_v1_version"
  printf '200\n{"login":"bob"}'      > "$d/api_v1_users_bob"
  stub_server "$d"
  run env -u FORGE_ORG FORGE_BASE_URL="http://127.0.0.1:$STUB_PORT" LCARS_HUMAN=bob "$PROBES/40-forge.sh"
  stub_stop
  echo "$output" | jq -e 'select(.probe=="forge.org") | .verdict=="inactive"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="forge.human_account") | .verdict=="operational"' >/dev/null
}

# ── 50-projects : les liaisons par construction ───────────────────────────────────────────────────
# Toutes hermetiques : des depots git reels dans le TMP, et un arbre de source MINIMAL qui joue le
# role de la declaration. C'est le point : la sonde ne porte aucune attente, elle va la lire — donc
# un test peut la DEPLACER et verifier que le verdict suit. Un check code en dur serait intestable
# de cette facon, et c'est exactement ce qui le rend fragile en production.

mk_decl() { # <projects_root> <depot> <branche livrable> <branche work> [<work_root declare>]
  local root="$1" name="$2" mb="$3" wb="$4" wr="${5:-$TMP/w}" d
  d="$root/$name/fleet/runtime/lib/fleet"; mkdir -p "$d/pilot"
  printf '%s\n' \
    "    GitOps.run([\"clone\", \"--branch\", \"$mb\", url, proj_dir], auth: true)" \
    "    with :ok <- GitOps.run([\"init\", \"-q\", \"-b\", \"$wb\", work_dir], auth: false) do" \
    > "$d/pilot/project_onboard.ex"
  printf '%s\n' "  @projects_root \"$root\"" "  @work_root \"$wr\"" > "$d/layout.ex"
}

mk_repo() { # <dir> <branche> [origin]
  mkdir -p "$1"; git init -q -b "$2" "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  [[ -n "${3:-}" ]] && git -C "$1" remote add origin "$3"
  return 0
}

# Simule un `fetch` deja fait, sans reseau : la ref de suivi est un ref comme un autre.
mk_tracking() { git -C "$1" update-ref "refs/remotes/origin/$2" "${3:-$(git -C "$1" rev-parse HEAD)}"; }

sotf50() { env SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/w" LCARS_POD_HOME="$TMP/nohome" "$PROBES/50-projects.sh"; }

@test "50-projects : boite fraiche — 0 projet et aucune source n'est PAS un angle mort" {
  # La faute d'origine, refaite ici sous une autre forme : declarer `unreachable` sur une declaration
  # dont personne n'a besoin faisait basculer tout le run en AVEUGLE pour une question non posee.
  mkdir -p "$TMP/p" "$TMP/w"
  run sotf50
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'select(.probe=="projects.declaration") | .verdict=="inactive"' >/dev/null
}

@test "50-projects : des projets SANS declaration lisible, c'est un vrai angle mort" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" main
  run sotf50
  [ "$status" -eq 2 ]
  echo "$output" | jq -e 'select(.probe=="projects.declaration") | .verdict=="unreachable"' >/dev/null
  # et l'observable est rapporte SANS attente : jamais vert, jamais rouge
  echo "$output" | jq -e 'select(.probe=="projects.alpha.etat") | .verdict=="unknown"' >/dev/null
}

@test "50-projects : l'attente est LUE dans la source — la deplacer deplace le verdict" {
  # LA propriete qui distingue une liaison d'un check. Meme disque, meme sonde, deux declarations :
  # deux verdicts. Aucun litteral de branche n'existe dans la sonde pour qu'on puisse le faire.
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" trunk
  mk_decl "$TMP/p" src main work/ops
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.branch") | .verdict=="degraded"' >/dev/null
  mk_decl "$TMP/p" src trunk work/ops
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.branch") | .verdict=="operational"' >/dev/null
}

@test "50-projects : un sous-dossier d'un depot n'est pas un projet" {
  # `git rev-parse` repond « oui » depuis n'importe quel sous-dossier : sans l'egalite avec la
  # RACINE, tout dossier interne passerait pour un depot et l'inventaire inventerait des projets.
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" main; mkdir -p "$TMP/p/alpha/sub"
  run bash -c ". $PROBES/lib.sh; . /dev/stdin <<< \"\$(sed -n '/^is_repo()/,/^}/p' $PROBES/50-projects.sh)\"; is_repo $TMP/p/alpha && echo RACINE; is_repo $TMP/p/alpha/sub || echo PAS-SOUS-DOSSIER"
  echo "$output" | grep -qx RACINE
  echo "$output" | grep -qx PAS-SOUS-DOSSIER
}

@test "50-projects : un .git FICHIER (worktree lie) reste un depot" {
  # Le cas qui a fait dire « cote work ABSENT » sur un depot parfaitement present.
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" worktree add -q -b wt "$TMP/w/alpha" >/dev/null 2>&1
  [ -f "$TMP/w/alpha/.git" ]
  run bash -c ". $PROBES/lib.sh; . /dev/stdin <<< \"\$(sed -n '/^is_repo()/,/^}/p' $PROBES/50-projects.sh)\"; is_repo $TMP/w/alpha && echo OUI"
  echo "$output" | grep -qx OUI
}

@test "50-projects : un dossier a point n'est pas un projet (Layout refuse le point initial)" {
  mkdir -p "$TMP/p/.claude" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  run sotf50
  ! echo "$output" | jq -e 'select(.probe|startswith("projects..claude"))' >/dev/null
}

@test "50-projects : sale cote livrable = drift, sale cote work = etat de travail normal" {
  # L'ASYMETRIE. Le meme fait git ne dit pas la meme chose des deux cotes : `reset --hard` ECRASE le
  # livrable, tandis que le cote work est un depot autonome ou l'on travaille. Traiter les deux
  # pareil rend rouge du benin et vert ce qui se perd.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main; mk_repo "$TMP/w/alpha" work/ops
  mk_tracking "$TMP/p/alpha" main; mk_tracking "$TMP/w/alpha" work/ops
  touch "$TMP/p/alpha/sale" "$TMP/w/alpha/sale"
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.clean") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="projects.alpha.clean") | .evidence | contains("ecrase")' >/dev/null
  echo "$output" | jq -e 'select(.probe=="projects.alpha.work_unpushed") | .verdict=="operational"' >/dev/null
}

@test "50-projects : du work/ops non pousse est LE seul etat ou une perte est possible" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/w/alpha" work/ops; mk_tracking "$TMP/w/alpha" work/ops
  git -C "$TMP/w/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m inedit
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.work_unpushed") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="projects.alpha.work_unpushed") | .evidence | contains("que sur ce disque")' >/dev/null
}

@test "50-projects : un miroir en retard est un DISQUE EN RETARD, il est nomme comme tel" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main; mk_tracking "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m devant
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.mirror") | .verdict=="degraded"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="projects.alpha.mirror") | .cannot_conclude | contains("jamais une perte")' >/dev/null
}

@test "50-projects : sans ref de suivi, unknown — jamais 'aligne' par defaut" {
  # Un depot jamais fetch n'a rien a comparer. Rendre `operational` la ferait passer pour a jour.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops; mk_repo "$TMP/p/alpha" main
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.alpha.mirror") | .verdict=="unknown"' >/dev/null
}

@test "50-projects : l'identite compare a la CASSE — Layout.project_name ne replie rien" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/Alpha" main "http://forge.test/fleet/alpha.git"
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.Alpha.identity") | .verdict=="degraded"' >/dev/null
}

@test "50-projects : un identifiant dans l'origin ne sort NI dans l'evidence NI dans la methode" {
  # Un rapport finit dans un log de conversation. L'evidence est verbatim par contrat, et le verbatim
  # est exactement ce qu'un credential ne doit pas etre. Deuxieme effet, aussi important : l'URL
  # SERVIE a curl est desidentifiee, sinon la lecture « anonyme » devient authentifiee en silence et
  # tout ce que la liaison declare sur le 404 ambigu devient faux.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main "http://bob:s3cr3t@127.0.0.1:1/fleet/alpha.git"
  run sotf50
  ! echo "$output" | grep -q "s3cr3t"
  echo "$output" | jq -e 'select(.probe=="projects.alpha.identity") | .evidence | contains("***@")' >/dev/null
}

@test "50-projects : une racine non montee est un cloisonnement, pas une panne" {
  # Seul starfleet monte les deux racines. Pour tout autre role l'absence est CONSTRUCTIVE, et la
  # peindre en rouge apprendrait a ignorer le rouge.
  mkdir -p "$TMP/p" "$TMP/pod"
  printf '{"metadata":{"mounts":[{"path":"/home/projects"}]}}' > "$TMP/pod/.cap-profile.json"
  run env SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/absente" LCARS_POD_HOME="$TMP/pod" "$PROBES/50-projects.sh"
  echo "$output" | jq -e 'select(.probe=="projects.root_work") | .verdict=="inactive"' >/dev/null
}

@test "50-projects : une racine DECLAREE au cap-profile et illisible est un drift" {
  mkdir -p "$TMP/p" "$TMP/pod"
  printf '{"metadata":{"mounts":[{"path":"%s"}]}}' "$TMP/absente" > "$TMP/pod/.cap-profile.json"
  run env SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/absente" LCARS_POD_HOME="$TMP/pod" "$PROBES/50-projects.sh"
  echo "$output" | jq -e 'select(.probe=="projects.root_work") | .verdict=="degraded"' >/dev/null
}

@test "50-projects : sonder une autre racine que celle de Fleet.Layout invalide tout le reste" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops "/ailleurs"
  run sotf50
  echo "$output" | jq -e 'select(.probe=="projects.roots_agree") | .verdict=="degraded"' >/dev/null
}

@test "50-projects : sans git, l'angle mort est TOTAL et il le dit — pas 'aucun projet'" {
  # Sans ce garde, chaque liaison rendrait « pas de depot » sur des projets sains : le silence de
  # l'instrument se lirait comme un constat d'absence.
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" main
  local bin="$TMP/nogit"; mkdir -p "$bin"
  local t p
  # `dirname` en tete : la sonde s'en sert pour se localiser AVANT de sourcer lib.sh. L'oublier ne
  # produit pas un run sans git, il produit un run sans rien — et un test qui mesure l'effondrement
  # d'un harnais croit mesurer le comportement qu'il visait.
  for t in bash dirname jq date id find sed grep wc awk head tr sort comm env curl cut; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$bin/$t"
  done
  run env -i PATH="$bin" HOME="$TMP" SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/w" \
    "$bin/bash" "$PROBES/50-projects.sh"
  [ "$status" -eq 2 ]
  echo "$output" | jq -e 'select(.probe=="projects.instrument") | .verdict=="unreachable"' >/dev/null
  ! echo "$output" | jq -e 'select(.probe=="projects.inventory")' >/dev/null
}
