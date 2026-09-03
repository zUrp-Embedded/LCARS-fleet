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

# ── Reading a probe out of the report, WITHOUT `jq -e` ────────────────────────────────────────────
#
# `jq -e` sets its exit status from the LAST value it produced, and `select` produces NOTHING for
# the lines it rejects. So `jq -e 'select(.probe=="X") | .verdict=="Y"'` over a JSONL report asks a
# question whose answer depends on WHERE X sits in the stream — and jq changed that behaviour
# between releases.
#
# Measured 2026-08-07, same corpus, two jq builds:
#
#     jq 1.7 (workstation)    a match anywhere      -> rc 0
#     jq 1.6 (build image)    a match NOT last      -> rc 4 ("no output"), whatever the verdict
#
# 28 tests were green here and red in the container, every one of them a correct assertion about a
# correct probe. The NEGATED forms were worse and failed the other way: `! … jq -e 'select(P)'`
# passed as "probe P is absent" whenever P was merely not the last line — a false GREEN about the
# exact thing the test existed to forbid.
#
# The fix is not a jq version floor. It is to stop asking jq for a verdict: we ask it for a VALUE
# and compare in bash, where "absent" and "present but wrong" are two different strings and both are
# printed when the assertion fails.
#
# The `grep '^{'` is load-bearing: several specimens deliberately mix a text marker into the run's
# output, and jq would abort on that line, reddening the test for the wrong reason.

probe_field() {  # $1 = probe name, $2 = field — empty when the probe emitted nothing
  printf '%s\n' "$output" | grep '^{' | jq -r --arg p "$1" --arg f "$2" 'select(.probe==$p) | .[$f]'
}

probe_names() {  # every probe name in the report, one per line
  printf '%s\n' "$output" | grep '^{' | jq -r '.probe'
}

assert_verdict() {  # $1 = probe, $2 = expected verdict
  local got; got="$(probe_field "$1" verdict)"
  [ "$got" = "$2" ] && return 0
  echo "probe $1 : verdict '$got', attendu '$2'" >&2
  return 1
}

assert_field_contains() {  # $1 = probe, $2 = field, $3 = needle
  local got; got="$(probe_field "$1" "$2")"
  case "$got" in *"$3"*) return 0 ;; esac
  echo "probe $1 : .$2 ne contient pas '$3' — vu : '$got'" >&2
  return 1
}

refute_field_contains() {
  local got; got="$(probe_field "$1" "$2")"
  case "$got" in *"$3"*) echo "probe $1 : .$2 contient '$3' alors qu'il ne devrait pas — vu : '$got'" >&2; return 1 ;; esac
  return 0
}

assert_field_starts() {  # $1 = probe, $2 = field, $3 = prefix
  local got; got="$(probe_field "$1" "$2")"
  case "$got" in "$3"*) return 0 ;; esac
  echo "probe $1 : .$2 ne commence pas par '$3' — vu : '$got'" >&2
  return 1
}

refute_field_starts() {
  local got; got="$(probe_field "$1" "$2")"
  case "$got" in "$3"*) echo "probe $1 : .$2 commence par '$3' alors qu'il ne devrait pas — vu : '$got'" >&2; return 1 ;; esac
  return 0
}

assert_probe() {  # the probe emitted a line at all
  probe_names | grep -qxF "$1" && return 0
  echo "probe $1 : absente du rapport — sondes vues : $(probe_names | tr '\n' ' ')" >&2
  return 1
}

refute_probe() {
  probe_names | grep -qxF "$1" || return 0
  echo "probe $1 : presente alors qu'elle ne devrait pas l'etre" >&2
  return 1
}

refute_probe_prefix() {  # no probe name may START with $1 (prefix, not substring)
  local hit
  hit="$(probe_names | while IFS= read -r n; do case "$n" in "$1"*) echo "$n" ;; esac; done)"
  [ -z "$hit" ] && return 0
  echo "prefixe '$1' : sonde(s) presente(s) alors qu'aucune ne devrait l'etre — $(echo "$hit" | tr '\n' ' ')" >&2
  return 1
}

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

# ── Socket obs (fleet socket-only) ────────────────────────────────────────────────────────────────

@test "socket obs : chemin par humain par defaut, override par LCARS_OBS_SOCK" {
  # La fleet est socket-only : il n'y a plus de port TCP a deriver. Le deck ecoute un socket AF_UNIX
  # par humain sous <console_root>/<humain>/deck.sock — chacun n'atteint QUE le sien, ce qui fait
  # disparaitre l'ancienne ambiguite « mauvais daemon / fleet du voisin ».
  #
  # 2. defaut : ni override, racine deplacable pour le test via SOTF_CONSOLE_ROOT
  run env -u LCARS_OBS_SOCK SOTF_CONSOLE_ROOT="$TMP/console" bash -c \
    '. '"$PROBES"'/lib.sh; echo "$(sotf_obs_sock)|$(sotf_url_origin)"'
  [[ "$output" == "$TMP/console/$(id -un)/deck.sock|"* ]]
  [[ "$output" == *"|socket par defaut"* ]]

  # 1. l'override operateur bat le chemin par defaut
  run env LCARS_OBS_SOCK="$TMP/custom.sock" bash -c \
    '. '"$PROBES"'/lib.sh; echo "$(sotf_obs_sock)|$(sotf_url_origin)"'
  [[ "$output" == "$TMP/custom.sock|override LCARS_OBS_SOCK" ]]
}

@test "la garde « rien a atteindre » : pas de run dir → inactive, jamais degraded ni unreachable" {
  # THE rule the two specimens forced into existence, and the reason it lives in lib.sh: it was
  # hand-copied into three probes and produced three DIFFERENT verdicts for one situation.
  run env LCARS_RUN_DIR="$TMP/vide" bash -c \
    '. '"$PROBES"'/lib.sh; sotf_init; sotf_skip_no_fleet x.y fleet "sans objet" && echo "SKIP=oui"'
  echo "$output" | grep -q "SKIP=oui"
  assert_verdict x.y inactive

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

  # Le 3e argument bascule le transport sur un socket AF_UNIX (la fleet est socket-only). Un socket
  # inexistant fait echouer la CONNEXION, pas l'outil : rc=0 et code=000, comme un TCP refuse.
  run bash -c '. '"$PROBES"'/lib.sh; http_probe "http://localhost/x" 2 "'"$TMP"'/absent.sock"; echo "rc=$? code=$SOTF_HTTP_CODE"'
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
  assert_verdict instruments.mcp_socket inactive
  assert_verdict instruments.mcp_bridge inactive
}

@test "un outil requis absent : degraded sur l'inventaire, unreachable sur ce qui en dependait" {
  # One missing tool, TWO verdicts, both correct. Conflating them reports a live fleet as dead, or a
  # dead one as unmeasured.
  local fake="$TMP/bin2"; mkdir -p "$fake"
  for t in bash dirname basename date id tr grep head cat jq git; do
    for d in /usr/bin /bin; do [ -x "$d/$t" ] && { ln -sf "$d/$t" "$fake/$t"; break; }; done
  done
  # LCARS_RUN_DIR EXPLICITE, et il doit EXISTER : sans lui la sonde d'endpoint dit « aucune fleet
  # demarree » et sort en 1, pas en 2. Le test passait alors sur le poste du developpeur — dont le
  # ~/.lcars/run existe — et rougissait dans toute boite neuve, ce que le corpus interdit deux tests
  # plus haut : « sinon le test mesure ce que la machine du DEVELOPPEUR a ».
  mkdir -p "$TMP/run"
  run env PATH="$fake" LCARS_RUN_DIR="$TMP/run" "$PROBES/10-instruments.sh"
  [ "$status" -eq 2 ]
  assert_verdict instruments.shell_tools degraded
  assert_verdict instruments.endpoint_deck unreachable
}

@test "bridge MCP : un interpreteur declare mais absent est nomme (le cas A-1)" {
  # The failure that cost a live starfleet an eight-hour session to establish by hand.
  local home="$TMP/pod"; mkdir -p "$home"
  cat > "$home/.mcp-fleet.json" <<'JSON'
{"mcpServers":{"fleet":{"command":"bash","args":["-c","exec pythonXX /x/bridge.py"]}}}
JSON
  run env LCARS_POD_ID=p1 LCARS_ROLE=starfleet LCARS_POD_HOME="$home" "$PROBES/10-instruments.sh"
  assert_verdict instruments.mcp_bridge degraded
  assert_field_contains instruments.mcp_bridge evidence 'pythonXX'
}

@test "bridge MCP : une declaration illisible rend unknown, jamais un faux vert" {
  local home="$TMP/pod2"; mkdir -p "$home"
  echo '{"mcpServers":{}}' > "$home/.mcp-fleet.json"
  run env LCARS_POD_ID=p1 LCARS_POD_HOME="$home" "$PROBES/10-instruments.sh"
  assert_verdict instruments.mcp_bridge unknown
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
  # `[[ ]]` plutot que `! … | grep` : un test avec operateur `!=` n'est pas une commande niee,
  # donc errexit y mord (cf. deploy/tests/refute.bash). La skill n'importe aucun helper —
  # c'est le seul objet d'ici concu pour voyager sans le depot.
  [[ "$output" != *"limite-A"* ]] || { printf 'INTERDIT : « limite-A » dans la sortie :\n%s\n' "$output" >&2; false; }
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

# The socket twin of stub_server: the fleet is socket-only, so the pod probes now dial an AF_UNIX
# socket (`curl --unix-socket`). Serves the same file-per-route corpus over a UnixStreamServer, so
# the REAL curl path is exercised. BaseHTTPRequestHandler wants a (host, port) client_address tuple
# that a unix socket does not provide, hence the get_request override.
stub_unix_server() {
  local dir="$1" sock="$2"
  python3 - "$dir" "$sock" <<'PY' &
import http.server, socketserver, sys, os
d, sockpath = sys.argv[1], sys.argv[2]
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
class S(socketserver.UnixStreamServer):
    def get_request(self):
        req, _ = super().get_request()
        return req, ("localhost", 0)
if os.path.exists(sockpath): os.remove(sockpath)
with S(sockpath, H) as s:
    open(os.path.join(d, ".ready"), "w").write("1")
    s.serve_forever()
PY
  STUB_PID=$!
  for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.05; done
}

@test "30-pods : zero pod vivant est un etat legitime (operational), jamais un drift" {
  # An idle fleet must not be permanently red — un 200 avec liste vide se lit operational, avec le
  # compte dans l'evidence.
  local d="$TMP/stub3"; mkdir -p "$d"
  printf '200\n{"pods":[]}' > "$d/api_pods"
  local sock="$TMP/deck3.sock"
  stub_unix_server "$d" "$sock"
  mkdir -p "$TMP/run"
  run env LCARS_RUN_DIR="$TMP/run" LCARS_OBS_SOCK="$sock" "$PROBES/30-pods.sh"
  stub_stop
  assert_verdict pods.live operational
  assert_field_contains pods.live evidence '0 pod'
}

@test "30-pods : un endpoint pods muet n'est PAS zero pod — il degrade" {
  # La regression a ne pas rouvrir : un endpoint absent (404) ne doit jamais se rendre en silence
  # « 0 pod ». Le stub ne sert rien pour /api/pods → 404 → degraded, sans faux compte.
  local d="$TMP/stub3b"; mkdir -p "$d"
  local sock="$TMP/deck3b.sock"
  stub_unix_server "$d" "$sock"
  mkdir -p "$TMP/run"
  run env LCARS_RUN_DIR="$TMP/run" LCARS_OBS_SOCK="$sock" "$PROBES/30-pods.sh"
  stub_stop
  assert_verdict pods.live degraded
  refute_field_contains pods.live evidence '0 pod'
}

@test "40-forge : sans FORGE_BASE_URL c'est inactive — rien de declare n'est pas un angle mort" {
  # Corrige apres mesure : `unreachable` faisait basculer tout le rapport en AVEUGLE sur une boite
  # saine dont personne n'avait configure de forge. Mon instrument n'est pas casse, il n'y a
  # simplement rien a atteindre. Et `degraded` serait pire : une affirmation sur une forge jamais
  # contactee.
  run env -u FORGE_BASE_URL "$PROBES/40-forge.sh"
  assert_verdict forge.configured inactive
  assert_verdict forge.org inactive
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
  assert_verdict forge.org unknown
  assert_field_contains forge.org cannot_conclude 'invisible'
}

@test "40-forge : un service qui repond sans etre une forge est degraded, pas operational" {
  local d="$TMP/stub5"; mkdir -p "$d"
  stub_server "$d"   # rien de servi → 404 partout, y compris /api/v1/version
  run env FORGE_BASE_URL="http://127.0.0.1:$STUB_PORT" "$PROBES/40-forge.sh"
  stub_stop
  assert_verdict forge.reachable degraded
}

@test "40-forge : aucun credential dans un pod est ATTENDU (inactive), pas une faute" {
  # ⚠ `LCARS_ROLES_SOCKET` POINTE SUR UN CHEMIN QUI N'EXISTE PAS, ET C'EST DELIBERE : c'est la
  # situation d'un pod, ou aucune socket de la boite n'est montee. Laisser le defaut
  # (`/run/lcars/authority/roles.sock`) ferait passer ce temoin au ROUGE sur toute machine de dev
  # qui fait tourner le service — et au vert ailleurs, pour une raison qui n'est pas la sienne.
  run env LCARS_ROLES_SOCKET="$TMP/pas-de-socket" HOME="$TMP" "$PROBES/40-forge.sh"
  assert_verdict forge.credentials inactive
}

# LE TEMOIN DU TEMOIN, ET IL EST LE SEUL A PROUVER QUE LA SONDE MESURE ENCORE QUELQUE CHOSE. Sans
# lui, une sonde rendant `inactive` INCONDITIONNELLEMENT — parce qu'elle teste un chemin que plus
# personne ne pose, par exemple — passerait l'assertion ci-dessus en n'ayant rien regarde. C'est
# exactement le defaut que cette sonde vient de porter pendant tout un chantier.
@test "40-forge : une socket d'autorite PRESENTE rend operational" {
  local sock="$TMP/roles.sock"
  # UNE VRAIE SOCKET UNIX, PAS UN FICHIER. `test -S` distingue les deux ; poser un fichier ordinaire
  # epinglerait un `test -e` que la sonde ne fait pas, et le temoin passerait au vert sur une sonde
  # plus laxiste que celle qu'on croit avoir.
  python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$sock"
  run env LCARS_ROLES_SOCKET="$sock" HOME="$TMP" "$PROBES/40-forge.sh"
  assert_verdict forge.credentials operational
}

# ── 60-self : les liaisons declare↔observe ───────────────────────────────────────────────────────

@test "60-self : sans cap-profile, inactive — rien a confronter n'est pas une faute" {
  run env -u LCARS_POD_ID LCARS_POD_HOME="$TMP/vide" "$PROBES/60-self.sh"
  [ "$status" -eq 0 ]
  assert_verdict self.cap_profile inactive
}

@test "60-self : le pod NE LIT PAS une trace de launcher, meme posee sous son nez" {
  # Garde de non-regression de l'arbitrage 2026-08-15 : le launcher n'ecrit plus de trace dans le
  # pod (il tourne dans le bwrap, donc tout ce qu'il ecrit, l'agent confine le lit), et la sonde a
  # perdu `obs_launcher_tools` avec sa source. Le pod est AVEUGLE sur la divergence A-8, expres.
  #
  # Ce temoin est ecrit a l'envers des deux qu'il remplace : ils fabriquaient une trace et
  # verifiaient qu'elle etait LUE. Celui-ci en fabrique une — au format exact que l'ancienne sonde
  # cherchait, pour que le temoin echoue si quelqu'un recable le lecteur — et exige qu'il ne s'en
  # serve de rien. Une trace qui reapparaitrait sans lecteur reste un defaut, mais c'est le defaut
  # du launcher, tenu par ses propres bats.
  local h="$TMP/pod"; mkdir -p "$h"
  cat > "$h/.cap-profile.json" <<'JSON'
{"kind":"CapabilityProfile","metadata":{"name":"probe","containment":"bwrap"},
 "spec":{"scope":{"allowedTools":["Read","Bash"]},"knowledge":{"skills":[]}}}
JSON
  echo "[00:00:00] step jq tools OK allowed='Read,Bash,mcp__fleet__submit_result' disallowed='x'" > "$h/claude_launch.dbg"
  run env -u LCARS_POD_ID LCARS_POD_HOME="$h" "$PROBES/60-self.sh"
  # Aucune liaison `self.tools` n'est emise, et rien de la trace ne ressort dans le rapport.
  [[ "$output" != *"self.tools"* ]]
  [[ "$output" != *"submit_result"* ]]
  # Et l'angle mort est DECLARE, pas silencieux : `self.coverage` nomme le champ qui n'est plus
  # regarde. C'est ce qui separe « on a decide de ne pas voir » de « on a oublie de voir ».
  assert_field_contains self.coverage evidence 'spec.scope.allowedTools'
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
  assert_field_contains self.skills evidence 'alpha beta'
  refute_field_contains self.skills evidence '['
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
    assert_verdict "$p" unreachable
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
  assert_verdict self.coverage unknown
  # les champs sans liaison sont NOMMES
  assert_field_contains self.coverage evidence 'spec.brief_kind'
  # et le compteur n'est pas 1
  refute_field_starts self.coverage evidence '1/'
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
  assert_verdict forge.org inactive
  assert_verdict forge.human_account operational
}

# ── 50-projects : les liaisons par construction ───────────────────────────────────────────────────
# Toutes hermetiques : des depots git reels dans le TMP, et un arbre de source MINIMAL qui joue le
# role de la declaration. C'est le point : la sonde ne porte aucune attente, elle va la lire — donc
# un test peut la DEPLACER et verifier que le verdict suit. Un check code en dur serait intestable
# de cette facon, et c'est exactement ce qui le rend fragile en production.

mk_decl() { # <projects_root> <depot> <branche livrable> <branche work> [<work_root declare>]
  local root="$1" name="$2" mb="$3" wb="$4" wr="${5:-$TMP/w}" d
  d="$root/$name/fleet/lib/fleet"; mkdir -p "$d/pilot"
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
  assert_verdict projects.declaration inactive
}

@test "50-projects : des projets SANS declaration lisible, c'est un vrai angle mort" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" main
  run sotf50
  [ "$status" -eq 2 ]
  assert_verdict projects.declaration unreachable
  # et l'observable est rapporte SANS attente : jamais vert, jamais rouge
  assert_verdict projects.alpha.etat unknown
}

@test "50-projects : l'attente est LUE dans la source — la deplacer deplace le verdict" {
  # LA propriete qui distingue une liaison d'un check. Meme disque, meme sonde, deux declarations :
  # deux verdicts. Aucun litteral de branche n'existe dans la sonde pour qu'on puisse le faire.
  mkdir -p "$TMP/p" "$TMP/w"; mk_repo "$TMP/p/alpha" trunk
  mk_decl "$TMP/p" src main work/ops
  run sotf50
  assert_verdict projects.alpha.branch degraded
  mk_decl "$TMP/p" src trunk work/ops
  run sotf50
  assert_verdict projects.alpha.branch operational
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
  refute_probe_prefix projects..claude
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
  assert_verdict projects.alpha.clean degraded
  assert_field_contains projects.alpha.clean evidence 'ecrase'
  assert_verdict projects.alpha.work_unpushed operational
}

@test "50-projects : du work/ops non pousse est LE seul etat ou une perte est possible" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/w/alpha" work/ops; mk_tracking "$TMP/w/alpha" work/ops
  git -C "$TMP/w/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m inedit
  run sotf50
  assert_verdict projects.alpha.work_unpushed degraded
  assert_field_contains projects.alpha.work_unpushed evidence 'que sur ce disque'
}

@test "50-projects : EN AVANCE sur le miroir = commits condamnes, pas un disque en retard" {
  # Mesure sur le conteneur docker : son clone du livrable portait 4 commits presents nulle part
  # ailleurs, et la sonde repondait « un ecart reste un disque en retard, jamais une perte ». Vrai
  # pour le retard, FAUX pour l'avance : `reset --hard origin/main` detruit des commits aussi bien
  # que des fichiers. Une ligne qui mesure juste et rassure a tort est pire qu'une ligne absente.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main; mk_tracking "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m devant
  run sotf50
  assert_verdict projects.alpha.mirror degraded
  assert_field_contains projects.alpha.mirror evidence 'AUCUNE ref distante'
  assert_field_contains projects.alpha.mirror evidence 'DETRUIT'
  refute_field_contains projects.alpha.mirror cannot_conclude 'jamais une perte'
}

@test "50-projects : en avance MAIS presents sur une autre ref distante = ecart, pas perte" {
  # La correction de la correction. « En avance » et « perdu au reset » sont deux choses : la sonde
  # a annonce « n'existent QUE sur ce disque » sur six commits qui dormaient sur une branche poussee.
  # Un miroir qui n'en est plus un reste un ecart ; ce n'est pas pour autant du travail en danger.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main; mk_tracking "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m devant
  # le meme commit vit aussi sur une ref distante : c'est ce qui change la lecture
  mk_tracking "$TMP/p/alpha" chantier/x
  run sotf50
  assert_verdict projects.alpha.mirror degraded
  assert_field_contains projects.alpha.mirror evidence 'SANS les perdre'
  refute_field_contains projects.alpha.mirror evidence 'DETRUIT'
}

@test "50-projects : EN RETARD sur le miroir = benin, et c'est dit comme tel" {
  # Le jumeau. Meme verdict `degraded`, lecture opposee : ici le sync repare tout seul.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m devant
  mk_tracking "$TMP/p/alpha" main
  git -C "$TMP/p/alpha" reset -q --hard HEAD~1
  run sotf50
  assert_verdict projects.alpha.mirror degraded
  assert_field_contains projects.alpha.mirror evidence 'le prochain sync les rattrape'
}

@test "50-projects : sans ref de suivi, unknown — jamais 'aligne' par defaut" {
  # Un depot jamais fetch n'a rien a comparer. Rendre `operational` la ferait passer pour a jour.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops; mk_repo "$TMP/p/alpha" main
  run sotf50
  assert_verdict projects.alpha.mirror unknown
}

@test "50-projects : l'identite compare a la CASSE — Layout.project_name ne replie rien" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/Alpha" main "http://forge.test/fleet/alpha.git"
  run sotf50
  assert_verdict projects.Alpha.identity degraded
}

@test "50-projects : un identifiant dans l'origin ne sort NI dans l'evidence NI dans la methode" {
  # Un rapport finit dans un log de conversation. L'evidence est verbatim par contrat, et le verbatim
  # est exactement ce qu'un credential ne doit pas etre. Deuxieme effet, aussi important : l'URL
  # SERVIE a curl est desidentifiee, sinon la lecture « anonyme » devient authentifiee en silence et
  # tout ce que la liaison declare sur le 404 ambigu devient faux.
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops
  mk_repo "$TMP/p/alpha" main "http://bob:s3cr3t@127.0.0.1:1/fleet/alpha.git"
  run sotf50
  [[ "$output" != *"s3cr3t"* ]] || { printf 'FUITE : « s3cr3t » dans la sortie de la sonde :\n%s\n' "$output" >&2; false; }
  assert_field_contains projects.alpha.identity evidence '***@'
}

@test "50-projects : une racine non montee est un cloisonnement, pas une panne" {
  # Seul starfleet monte les deux racines. Pour tout autre role l'absence est CONSTRUCTIVE, et la
  # peindre en rouge apprendrait a ignorer le rouge.
  mkdir -p "$TMP/p" "$TMP/pod"
  printf '{"metadata":{"mounts":[{"path":"/home/projects"}]}}' > "$TMP/pod/.cap-profile.json"
  run env SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/absente" LCARS_POD_HOME="$TMP/pod" "$PROBES/50-projects.sh"
  assert_verdict projects.root_work inactive
}

@test "50-projects : une racine DECLAREE au cap-profile et illisible est un drift" {
  mkdir -p "$TMP/p" "$TMP/pod"
  printf '{"metadata":{"mounts":[{"path":"%s"}]}}' "$TMP/absente" > "$TMP/pod/.cap-profile.json"
  run env SOTF_PROJECTS_ROOT="$TMP/p" SOTF_WORK_ROOT="$TMP/absente" LCARS_POD_HOME="$TMP/pod" "$PROBES/50-projects.sh"
  assert_verdict projects.root_work degraded
}

@test "50-projects : sonder une autre racine que celle de Fleet.Layout invalide tout le reste" {
  mkdir -p "$TMP/p" "$TMP/w"; mk_decl "$TMP/p" src main work/ops "/ailleurs"
  run sotf50
  assert_verdict projects.roots_agree degraded
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
  assert_verdict projects.instrument unreachable
  refute_probe projects.inventory
}

# ── sotf.sh : le raisonnement de capacite ─────────────────────────────────────────────────────────
# Teste sur un FLUX SYNTHETIQUE, jamais sur la machine : `diag` repond « qu'est-ce qui est
# entreprenable », et cette reponse est une projection sur des verdicts de sondes. En la testant a
# travers de vraies sondes on mesurerait l'etat du poste, pas la regle — et la regle est precisement
# ce qui doit tenir sur un poste qu'on ne connait pas.

load_sotf() { . "$SKILL_DIR/sotf.sh"; }   # garde de source : sourcer ne lance rien

jl() { # construit une ligne de flux : <probe> <verdict> [evidence]
  jq -cn --arg p "$1" --arg v "$2" --arg e "${3:-ev}" \
    '{probe:$p,plane:"x",verdict:$v,vantage:"local",method:"m",evidence:$e,cannot_conclude:"c",ts:"t"}'
}

@test "sotf : tous les maillons verts → la capacite est entreprenable" {
  load_sotf
  JSONL="$(jl instruments.mcp_socket operational)
$(jl fleet.health operational)
$(jl fleet.subsystem.mcp.pod_facing operational)"
  run capability_verdict "$(chain_of card_list)"
  [[ "$output" == operational\|* ]]
}

@test "sotf : un maillon bloquant casse NOMME le maillon ET son constat" {
  # `diag` se lit par quelqu'un qui est sur le point d'agir. Une ligne qui se contente d'un id
  # l'envoie fouiller le tableau — au moment precis ou il ne le fera pas.
  load_sotf
  JSONL="$(jl instruments.mcp_socket operational)
$(jl fleet.health degraded 'HTTP 503 sur /api/health')
$(jl fleet.subsystem.mcp.pod_facing operational)"
  run capability_verdict "$(chain_of card_list)"
  [[ "$output" == degraded\|* ]]
  echo "$output" | grep -q "fleet.health"
  echo "$output" | grep -q "503"
}

@test "sotf : un maillon INDICATIF rouge n'interdit pas — mais il interdit le vert" {
  # La distinction qui porte tout le fichier : un outil mcp est execute par la FLEET, pas par moi.
  # Ce que je mesure depuis ma place informe, ne tranche pas. La confondre avec du bloquant
  # declarerait project_create mort en permanence dans tout pod (aucun n'a de credential forge).
  load_sotf
  JSONL="$(jl instruments.mcp_socket operational)
$(jl fleet.health operational)
$(jl fleet.subsystem.mcp.pod_facing operational)
$(jl fleet.subsystem.spawn.dispatch operational)
$(jl forge.reachable degraded)
$(jl projects.root_projects operational)
$(jl projects.root_work operational)
$(jl fleet.subsystem.launch.backend operational)
$(jl fleet.subsystem.pilot.step operational)"
  run capability_verdict "$(chain_of project_create)"
  [[ "$output" == unknown\|* ]]
  echo "$output" | grep -q "forge.reachable"
}

@test "sotf : une chaine qui designe une sonde disparue le DIT, elle ne l'ignore pas" {
  # Le detecteur de derive de la chaine elle-meme. Sans lui, renommer une sonde rendrait
  # silencieusement toutes les capacites vertes : le maillon manquant ne bloquerait plus rien.
  load_sotf
  JSONL="$(jl instruments.mcp_socket operational)
$(jl fleet.health operational)"
  RAN_PLANES=" instruments fleet "   # les deux sondes ONT tourne : l'absence est donc une derive
  run capability_verdict "$(chain_of card_list)"
  [[ "$output" == unreachable\|* ]]
  echo "$output" | grep -q "fleet.subsystem.mcp.pod_facing"
}

@test "sotf : un maillon absent parce que sa sonde n'a pas tourne n'accuse rien" {
  # Le jumeau du test precedent, et c'est leur DIFFERENCE qui est la regle : court-circuit voulu
  # d'un cote, derive de l'autre. Les confondre ferait crier a la panne a chaque `diag` cible.
  load_sotf
  JSONL="$(jl instruments.mcp_socket operational)"
  RAN_PLANES=" instruments "
  run capability_verdict "$(chain_of card_list)"
  [[ "$output" == operational\|* ]]
}

@test "sotf : rien a atteindre reste inactive, ce n'est pas une panne" {
  load_sotf
  JSONL="$(jl instruments.mcp_socket inactive 'hors pod')"
  RAN_PLANES=" instruments "
  run capability_verdict "$(chain_of project_create)"
  [[ "$output" == inactive\|* ]]
}

@test "sotf : un fait constate passe devant un trou de mesure" {
  # degraded > unreachable : « c'est casse, et voila lequel » est plus actionnable que « je ne sais
  # pas ». L'inverse enterrerait la seule ligne exploitable du rapport.
  load_sotf
  JSONL="$(jl instruments.mcp_socket unreachable)
$(jl fleet.health degraded 'muet')
$(jl fleet.subsystem.mcp.pod_facing operational)"
  run capability_verdict "$(chain_of card_list)"
  [[ "$output" == degraded\|* ]]
}

@test "sotf : le code de sortie se derive du FLUX, pas des compteurs" {
  # Les sondes tournent dans des processus separes : leurs compteurs n'arrivent jamais au runner.
  # `--raw` rendait donc 0 sur un run aveugle — un succes ambigu, la faute que ce toolkit refuse.
  load_sotf
  JSONL="$(jl a.b operational)"; run jsonl_exit_code; [ "$output" = 0 ]
  JSONL="$(jl a.b degraded)";    run jsonl_exit_code; [ "$output" = 1 ]
  JSONL="$(jl a.b unreachable)"; run jsonl_exit_code; [ "$output" = 2 ]
  JSONL="$(jl a.b degraded)
$(jl c.d unreachable)"
  run jsonl_exit_code; [ "$output" = 2 ]
}

@test "sotf : les lignes de capacite sont DANS le flux, pas a cote" {
  # Hors du JSONL elles echapperaient au rendu, au comptage et au code de sortie — les trois choses
  # qui font qu'un rapport engage quelqu'un. C'est arrive : elles sortaient sur stdout, au-dessus.
  run env LCARS_POD_HOME="$TMP/nopod" "$SKILL_DIR/sotf.sh" diag --raw
  assert_probe capacites.project_create
  # aucune ligne non-JSON ne traine
  while read -r l; do [[ -z "$l" ]] || echo "$l" | jq -e . >/dev/null; done <<< "$output"
}

@test "sotf : le perimetre confronte les DEUX sens — outil sans chaine, chaine hors perimetre" {
  mkdir -p "$TMP/pod"
  printf '{"spec":{"scope":{"allowedTools":["Read","mcp__fleet__project_create","mcp__fleet__truc_inconnu"]}}}' \
    > "$TMP/pod/.cap-profile.json"
  run env LCARS_POD_HOME="$TMP/pod" "$SKILL_DIR/sotf.sh" diag --raw
  assert_verdict capacites.perimetre unknown
  assert_field_contains capacites.perimetre evidence 'truc_inconnu'
  assert_field_contains capacites.perimetre evidence 'project_open'
}

@test "sotf : une capacite inconnue est nommee comme telle, jamais evaluee en silence" {
  run env LCARS_POD_HOME="$TMP/nopod" "$SKILL_DIR/sotf.sh" diag pas_une_capacite --raw
  assert_verdict capacites.pas_une_capacite unreachable
}

@test "sotf : report refuse une cible, et une commande inconnue ne fait pas semblant" {
  run "$SKILL_DIR/sotf.sh" report project_create
  [ "$status" -eq 2 ]
  run "$SKILL_DIR/sotf.sh" rapport
  [ "$status" -eq 2 ]
}

# ── La doc et la CLI ──────────────────────────────────────────────────────────────────────────────

@test "SKILL.md ne documente aucune invocation que la CLI refuse" {
  # Une doc qui derive est un mensonge a retardement, et celle-ci est la seule chose qu'un agent lit
  # avant d'agir. Le detecteur est mecanique : les invocations sont EXTRAITES du markdown et
  # confrontees a ce que le case block accepte reellement. Renommer une entree des deux cotes est
  # gratuit ; ne la renommer que d'un cote rougit ici.
  local cmds opts c o
  cmds="$(grep -oE 'sotf\.sh [a-z_]+' "$SKILL_DIR/SKILL.md" | awk '{print $2}' | sort -u)"
  [ -n "$cmds" ]
  for c in $cmds; do
    grep -qE "^  $c\)|^  $c\|" "$SKILL_DIR/sotf.sh" || {
      echo "SKILL.md documente '$c', absent du case de sotf.sh"; return 1
    }
  done
  opts="$(grep -oE '^\s+\$S/sotf\.sh [^#]*' "$SKILL_DIR/SKILL.md" | grep -oE '\-\-[a-z]+' | sort -u)"
  for o in $opts; do
    grep -qE -- "$o\)|$o\|" "$SKILL_DIR/sotf.sh" "$SKILL_DIR/probes/render.sh" || {
      echo "SKILL.md documente l'option '$o', acceptee nulle part"; return 1
    }
  done
}

@test "FORMAT.md decrit les cinq verdicts que emit accepte, ni plus ni moins" {
  # Le vocabulaire a ete FORCE par deux specimens, pas conçu. Un sixieme verdict qui apparaitrait
  # dans le code sans passer par ce fichier reintroduirait exactement l'ambiguite qu'il a coute
  # cher de retirer.
  local v
  for v in operational inactive degraded unreachable unknown; do
    grep -q "\`$v\`" "$SKILL_DIR/FORMAT.md" || { echo "FORMAT.md ne decrit pas '$v'"; return 1; }
    grep -q "$v" "$PROBES/lib.sh" || { echo "lib.sh ne connait pas '$v'"; return 1; }
  done
  # aucun verdict dans le case de emit qui ne soit pas documente
  run bash -c "sed -n '/case \"\$verdict\" in/,/esac/p' '$PROBES/lib.sh' | grep -oE '^\s+[a-z|]+\)' | tr -d ' )' | tr '|' '\n' | grep -v '^\*$'"
  for v in $output; do
    grep -q "\`$v\`" "$SKILL_DIR/FORMAT.md" || { echo "verdict '$v' emis mais absent de FORMAT.md"; return 1; }
  done
}

# ── LA TABLE DES CHAINES EST UNE COPIE DE NOMS D'OUTILS ──────────────────────────────────────────
#
# ⚠ CE TEMOIN EXISTE PARCE QUE LA TABLE A DERIVE, DEUX FOIS, ET QUE PERSONNE NE L'A VU.
#
# Les ids d'outils sont passes objet-d'abord le 2026-08-11 (`create_project` -> `project_create`) et
# `list_workflow_cards` -> `card_list` le 2026-08-22. `CHAINS` a garde les QUATRE anciens noms
# jusqu'au 2026-08-22 : onze jours pour trois d'entre eux, et personne ne l'a vu — ce n'est pas la
# DUREE qui compte ici, c'est que rien ne pouvait le voir.
#
# Ce n'est pas de la prose perimee. `capacites.perimetre` CONFRONTE le `allowedTools` du pod a cette
# table dans les deux sens : chaque outil reel sortait « sans chaine » et chaque entree de la table
# sortait « hors perimetre ». La sonde ecrite pour detecter exactement cette derive la rapportait a
# chaque passage, et elle n'a de donnees que DANS un pod — invisible depuis le depot, noyee dans un
# rapport pour qui la lisait.
#
# Les deux murs Elixir (`mcp.tool_descriptions_name_real_tools`, `roles.tool_grants_resolve`) ne
# couvrent pas ce cas : l'un lit des descriptions Elixir, l'autre des cap-profiles. Aucun ne lit un
# script shell. Le mur va donc la ou vit la copie.
#
# DERIVE DE L'AUTORITE : `deftool` declare, cette table copie. Un outil renomme demain deplace ce
# temoin tout seul.
@test "sotf : chaque capacite de CHAINS est un outil MCP qui existe" {
  local tools_ex="$SKILL_DIR/../../../fleet/lib/fleet/mcp/pod_tools.ex"
  [ -f "$tools_ex" ] || skip "hors du depot (skill copie seul) — rien a confronter"

  local declared
  declared="$(grep -oE 'deftool "[a-z0-9_]+"' "$tools_ex" | sed 's/deftool "//; s/"//')"

  # GARDE D'INSTRUMENT : une forme de `deftool` qui change viderait la liste, et une liste vide
  # declarerait toutes les chaines valides — le vert exact que ce temoin existe pour refuser.
  [ "$(printf '%s\n' "$declared" | grep -c .)" -ge 12 ]

  # ⚠ LA TABLE SE LIT DANS LE FICHIER, PAS PAR `chain_names`. La premiere version appelait
  # `chain_names`, qui vit dans `sotf.sh` — que ce bats ne source PAS (il ne source que
  # `probes/lib.sh`). La fonction etait donc absente, la boucle tournait sur RIEN, et un ensemble
  # vide n'a aucun element fautif : le temoin restait vert avec la derive remise. Trouve par
  # mutation, le 2026-08-22, sur le temoin lui-meme.
  local chains
  chains="$(grep -oE '^"[a-z0-9_]+¤' "$SKILL_DIR/sotf.sh" | sed 's/^"//; s/¤$//')"

  # SECONDE GARDE D'INSTRUMENT, celle qui manquait : les DEUX cotes doivent avoir une population.
  [ "$(printf '%s\n' "$chains" | grep -c .)" -ge 4 ]

  local missing=""
  while read -r name; do
    [[ -z "$name" ]] && continue
    grep -qx -- "$name" <<< "$declared" || missing="$missing $name"
  done <<< "$chains"

  [[ -z "$missing" ]] || {
    echo "CHAINS nomme des outils qui n'existent pas :$missing" >&2
    false
  }
}
