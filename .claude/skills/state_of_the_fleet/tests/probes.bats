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

@test "les ports sont DERIVES de l'uid, jamais codes en dur" {
  # Two humans on one box get two blocks; a fixed 21000 would silently probe the neighbour's fleet
  # and report it as ours — a lie that looks perfectly healthy.
  unset LCARS_API_URL LCARS_OBS_URL
  local expected=$(( 21000 + ($(id -u) % 500) * 10 ))
  [ "$(sotf_port_base)" -eq "$expected" ]
  [ "$(sotf_api_url)" = "http://127.0.0.1:$expected" ]
  [ "$(sotf_obs_url)" = "http://127.0.0.1:$(( expected + 1 ))" ]
}

@test "une url declaree par l'env l'emporte, et l'origine est tracee" {
  LCARS_API_URL="http://ailleurs:1234/" run bash -c '. '"$PROBES"'/lib.sh; echo "$(sotf_api_url) $(sotf_url_origin)"'
  [[ "$output" == "http://ailleurs:1234 env" ]]
  unset LCARS_API_URL LCARS_OBS_URL
  [[ "$(sotf_url_origin)" == derive* ]]
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

@test "40-forge : sans FORGE_BASE_URL, c'est unreachable (aveugle) et jamais degraded" {
  # Saying `degraded` would be a claim about a forge we never contacted.
  run env -u FORGE_BASE_URL "$PROBES/40-forge.sh"
  echo "$output" | jq -e 'select(.probe=="forge.configured") | .verdict=="unreachable"' >/dev/null
  echo "$output" | jq -e 'select(.probe=="forge.org") | .verdict=="unreachable"' >/dev/null
}

@test "40-forge : un 404 anonyme sur l'org rend unknown, avec ses DEUX lectures" {
  # THE case the manual report caught by discipline: absent vs invisible-without-auth.
  local d="$TMP/stub4"; mkdir -p "$d"
  printf '200\n{"version":"1.26.4"}' > "$d/api_v1_version"
  stub_server "$d"
  run env FORGE_BASE_URL="http://127.0.0.1:$STUB_PORT" LCARS_HUMAN=someone "$PROBES/40-forge.sh"
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
