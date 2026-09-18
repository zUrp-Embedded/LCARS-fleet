#!/usr/bin/env bats
# SOURCE: runtime/test/bin/lcars.bats
# AUTHOR: consultant
# STARDATE: 2026-08-14
# STATUS: bats tests for `lcars forge` (pool) + `lcars approve` (phase-1 gate) fail-closed paths
#
# V2: auth is the forge CLI (gh/glab), so a forge carries NO token — the pool is host+owner+repo and
# the credential lives in the CLI's own store. V2.1: the CLI is OPTIONAL in approve — it is only NEEDED
# to CREATE a repo that does not exist (Tier 1); linking a pre-created repo + pushing use the operator's
# own wired helper (Tier 2). Covered: the guards that fire BEFORE any clone/push — pool validation,
# forge/binding resolution, that a logged-out CLI is NO LONGER a hard precondition, that --public
# parses, and the forge-config precondition. HOME is redirected to a tmp so ~/.lcars/{forges,publish}
# is controlled; gh/glab are stubbed. The real create/link/push are operator-exercised.

setup() {
  # ⚠ L'ENVIRONNEMENT DE LA MACHINE N'A PAS SON MOT A DIRE ICI. Ces temoins mesurent une ABSENCE de
  # forge ; si la variable existe deja dans l'environnement, ils mesurent la machine et passent au
  # rouge sans que rien ne soit casse. Mesure du 2026-08-18 : `provision --env` exporte
  # `FORGE_BASE_URL` (set -a) pour tout le run, gate compris — quatre temoins rouges sur une
  # installation parfaitement saine, et verts joues a la main.
  unset FORGE_BASE_URL FORGE_PUBLIC_URL FORGE_TOKEN_FILE FORGE_ADMIN_TOKEN
  SCRIPT="$BATS_TEST_DIRNAME/../../bin/lcars"
  TMP="$(mktemp -d)"
  export HOME="$TMP"                       # -> ~/.lcars resolves under TMP
  BIN="$TMP/bin"; mkdir -p "$BIN"

  # gh/glab stubs: `auth status` succeeds unless STUB_AUTHED=0 (the CLI-auth precondition probe).
  for cli in gh glab; do
    cat > "$BIN/$cli" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  [[ "${STUB_AUTHED:-1}" == "1" ]] && exit 0 || exit 1
fi
exit 0
STUB
    chmod +x "$BIN/$cli"
  done

  # git stub: `ls-remote` succeeds iff STUB_BASE_PRESENT=1 (the publish-status base-populated probe).
  # No other test invokes git (approve refuses at the forge-config check, before any clone).
  cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "ls-remote" ]]; then
  [[ "${STUB_BASE_PRESENT:-1}" == "1" ]] && exit 0 || exit 2
fi
exit 0
STUB
  chmod +x "$BIN/git"
  export PATH="$BIN:$PATH"
}

teardown() { rm -rf "$TMP"; }

@test "forge add: missing flags -> exit 1 (usage)" {
  run "$SCRIPT" forge add mine --host github
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "forge add: unknown host -> exit 1" {
  run "$SCRIPT" forge add mine --host bitbucket --owner alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"--host inconnu"* ]]
}

@test "forge add: name with a slash -> exit 1 (no path traversal)" {
  run "$SCRIPT" forge add "../evil" --host github --owner alice
  [ "$status" -eq 1 ]
  [[ "$output" == *"nom invalide"* ]]
}

@test "forge add then list: round-trip (no token, auth is the CLI)" {
  run "$SCRIPT" forge add mine --host gitlab --owner alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"enregistree"* ]]
  [[ "$output" == *"glab auth login"* ]]
  run "$SCRIPT" forge list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine"* ]]
  [[ "$output" == *"gitlab"* ]]
}

@test "approve: no repo -> exit 1 (usage)" {
  run "$SCRIPT" approve
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"* ]]
}

@test "approve: repo without slash -> exit 1" {
  run "$SCRIPT" approve notaslug
  [ "$status" -eq 1 ]
  [[ "$output" == *"n'est pas un owner/nom"* ]]
}

@test "approve: project not linked and no --forge -> exit 1" {
  run "$SCRIPT" approve fleet/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"pas encore lie"* ]]
}

@test "approve: --forge absent from pool -> exit 1" {
  run "$SCRIPT" approve fleet/demo --forge ghost --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"absente du pool"* ]]
}

@test "approve: --forge without --as -> exit 1" {
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  run "$SCRIPT" approve fleet/demo --forge mine
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige --as"* ]]
}

@test "approve: CLI not authenticated is NOT a hard precondition (falls to forge-config check)" {
  # V2.1: the CLI is only NEEDED to CREATE a repo. Logged out, approve no longer dies at 'auth login';
  # it falls through to the internal-forge config check (absent here) -> FORGE_BASE_URL absent, no push.
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  STUB_AUTHED=0 run "$SCRIPT" approve fleet/demo --forge mine --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL absent"* ]]
  [[ "$output" != *"auth login"* ]]
}

@test "approve: --public is a recognized flag (reaches forge-config check, not 'option inconnue')" {
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  run "$SCRIPT" approve fleet/demo --forge mine --as Demo --public
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL absent"* ]]
  [[ "$output" != *"option inconnue"* ]]
}

@test "approve: authed forge but no forge config -> exit 1 (FORGE_BASE_URL absent), nothing pushed" {
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  # gh stub is authed; no ~/.lcars/fleet.env -> the forge precondition refuses before any clone.
  run "$SCRIPT" approve fleet/demo --forge mine --as Demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"FORGE_BASE_URL absent"* ]]
}

# --- doctors: forge status + publish status (Lot 3b) -------------------------------------------------

@test "forge status: authenticated forge -> [ok]" {
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  run "$SCRIPT" forge status
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ok]"* ]]
  [[ "$output" == *"mine"* ]]
}

@test "forge status: not authenticated -> [!!] (auth login)" {
  "$SCRIPT" forge add mine --host github --owner alice >/dev/null
  STUB_AUTHED=0 run "$SCRIPT" forge status
  [ "$status" -eq 0 ]
  [[ "$output" == *"[!!]"* ]]
  [[ "$output" == *"auth login"* ]]
}

@test "publish status: unbound project -> calm (non lie, option), no nag" {
  run "$SCRIPT" publish status fleet/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"non lie (option)"* ]]
  [[ "$output" != *"[!!]"* ]]
}

@test "publish status: linked + authed + base present -> readiness all [ok]" {
  mkdir -p "$HOME/.lcars/publish"
  cat > "$HOME/.lcars/publish/fleet__demo.json" <<'J'
{"host":"github","dest_host":"github.com","dest_repo":"alice/Demo","base":"main"}
J
  STUB_BASE_PRESENT=1 run "$SCRIPT" publish status fleet/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"lie a github.com/alice/Demo"* ]]
  [[ "$output" == *"[ok] gh authentifie"* ]]
  [[ "$output" == *"phase 1 faite"* ]]
  [[ "$output" != *"[!!]"* ]]
}

# ⚠ L'AIDE DE CE CLI EST UN HEREDOC NON PROTÉGÉ (`cat >&2 <<EOF`), parce qu'elle interpole `$PROG`.
# Un accent grave non échappé y ouvre une SUBSTITUTION DE COMMANDE : le shell exécute ce qu'il y a
# entre les deux et met sa sortie — vide — à la place. L'aide perd alors le fragment, et rien ne le
# dit : elle s'imprime, elle a l'air normale, il manque juste un bout de phrase.
#
# Mesuré le 2026-09-17 : « sont declares (`Fleet.Layout.system_project/0`, le catalogue embarque) »
# s'imprimait « sont declares (, le catalogue embarque) ». Le plancher shellcheck n'attrape que le
# cas où le fragment contient aussi un `<` (qu'il lit comme une redirection) ; celui-là passait.
@test "aide : aucun accent grave non echappe dans le heredoc — sinon l'aide mange son propre texte" {
  local corps
  corps="$(awk '/^usage\(\) \{$/,/^EOF$/' "$SCRIPT")"
  [ -n "$corps" ]

  # un accent grave ECHAPPE (\`) est le seul admis ; tout autre ouvre une substitution
  local fautifs
  fautifs="$(grep -n '`' <<<"$corps" | grep -v '\\`' || true)"
  [ -z "$fautifs" ] || { echo "accents graves non echappes dans l'aide :"; echo "$fautifs"; return 1; }
}

@test "aide : chaque fragment entre accents graves SURVIT a l'impression — la mesure, pas la relecture" {
  local rendu; rendu="$(bash "$SCRIPT" --help 2>&1)"
  [ -n "$rendu" ]

  # l'instrument : ce que la source annonce, et ce que l'aide imprime vraiment
  local frag n=0
  while IFS= read -r frag; do
    n=$((n + 1))
    [[ "$rendu" == *"$frag"* ]] \
      || { echo "l'aide n'imprime pas « $frag » — un heredoc l'a substitue"; return 1; }
  done < <(awk '/^usage\(\) \{$/,/^EOF$/' "$SCRIPT" | grep -o '\\`[^`]*\\`' | sed 's/\\`//g')

  [ "$n" -ge 4 ] || { echo "instrument casse : $n fragment(s) trouve(s), au moins 4 attendus"; return 1; }
}

# ⚠ UN REPERTOIRE COURANT ILLISIBLE FAIT MOURIR LE BEAM, ET SA PLAINTE NE PARLE DE RIEN. Mesure du
# 2026-09-18 sur le banc 2004 : `lcars` lance depuis le home d'un AUTRE compte rend un « Kernel pid
# terminated (logger) » avec une pile `code_server`, puis ecrit un crash dump. Le meme geste dans un
# dossier lisible marche. Le refus nomme le dossier, le compte, et le geste qui repare.
@test "un repertoire courant ILLISIBLE est un refus NOMME, avant tout — pas un crash du BEAM" {
  [ "$(id -u)" -ne 0 ] || skip "a jouer sans privilege : root lit un repertoire en 000"
  local mur="$TMP/mur"
  mkdir -p "$mur"

  # ⚠ ON N'ENTRE PAS DANS UN DOSSIER A 000 : le cas REEL est un dossier qu'on habite et dont les
  # droits tombent — ce qui arrive des qu'un process garde le cwd d'un autre compte (`runuser`).
  run bash -c "cd '$mur' && chmod 000 '$mur' && '$SCRIPT' help"
  chmod 755 "$mur"

  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"n'est pas lisible par"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"cd ~"* ]]
  # ce que le crash rendait, et qu'on ne veut plus voir
  [[ "$output" != *"Kernel pid terminated"* ]]
}

@test "un repertoire courant LISIBLE ne refuse rien — le garde n'est pas un blocage permanent" {
  run bash -c "cd '$TMP' && '$SCRIPT' help"
  [[ "$output" != *"n'est pas lisible"* ]] || { echo "$output"; return 1; }
}
