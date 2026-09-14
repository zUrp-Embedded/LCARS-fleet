#!/usr/bin/env bats
# SOURCE: runtime/test/services/human.d/human_git_identity.bats
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: bats tests for 70-human — l'identite git de l'humain vient de son COMPTE FORGE
#
# CE QUE CES TEMOINS TIENNENT. Sans `user.email`, git signe `<login>@<hostname>` (`lcars@bridge` sur
# cette image) et la forge ne mappe cette adresse sur aucun compte : commit sans lien, sans avatar,
# attribue a un fantome. L'adresse qui mappe est celle du compte forge, et c'est la SEULE.
#
# CE QU'ILS ONT COUTE. Le bloc vivait dans l'entrypoint et posait l'identite de `LCARS_HUMAN` —
# l'unique humain du conteneur a l'epoque. `identity-v2` (b99d035f2) a fait de l'entree du conteneur
# le SYSADMIN : la substitution `LCARS_HUMAN` -> `LCARS_ADMIRAL` a suivi mecaniquement, et l'identite
# a atterri sur le seul compte qui ne commite jamais. Le commentaire au-dessus continuait de dire
# « l'email du compte forge de l'humain » — vrai, a cote d'un code qui ne le faisait plus, et le boot
# annoncait « identite git seedee » a chaque demarrage. Mesure du 2026-08-18, banc lcars-l8 :
# admiral <admiral@lcars.local>, `lcars` et `lordzurp` VIDES.
#
# Aucune socket : `curl` est une doublure en tete de PATH. Le module est charge SANS son dispatch
# final, pour appeler les deux fonctions directement — `check()`/`apply()` complets ecriraient dans
# le home reel de celui qui joue les tests.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../../support/refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../../services/human.d/70-human.sh"
  [ -f "$SRC" ]
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export FORGE_PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
  echo '{}' > "$FORGE_PAYLOAD"
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
cat "$FORGE_PAYLOAD"
SH
  chmod +x "$BIN/curl"

  # Le protocole cote PRODUIT (Q3, 2026-09-04), plus la lib de l'installeur.
  export LCARS_HUMAN_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/human-protocol.sh"
  export PROVISION_MODULE=70-human
  export LCARS_LOGIN
  LCARS_LOGIN="$(id -un)"
  export FORGE_BASE_URL="http://forge.test"
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  echo "tok" > "$LCARS_PRIVATE_DIR/system_starfleet.gitea_token"

  # HOME jetable : `as_human` s'execute DIRECTEMENT quand LCARS_LOGIN est deja l'utilisateur courant,
  # donc `git config --global` ecrit dans CE home et nulle part ailleurs.
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"

  # Le module sans son `case` final : on veut ses fonctions, pas son cycle complet.
  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"
  # ⚠ COUTURE OBLIGATOIRE PARCE QUE CE DECOR COPIE LE MODULE. Le fichier de reglages d'agent se
  # derive de `${BASH_SOURCE[0]}` — vrai en production, ou le module vit a cote de `../agent/` —
  # mais `$MOD` est une copie dans un tmpdir, ou ce frere n'existe pas. Sans cette ligne, les trois
  # temoins du garde-fou mesurent l'absence du decor au lieu de leur sujet.
  export LCARS_AUTOMODE_SRC="$BATS_TEST_DIRNAME/../../../services/agent/claude-automode.json"
  [ -f "$LCARS_AUTOMODE_SRC" ]
}

run_fn() { run bash -c "set -euo pipefail; source \"$MOD\"; $1"; }

account() { # account <full_name> <email>
  printf '{"login":"x","full_name":"%s","email":"%s"}\n' "$1" "$2" > "$FORGE_PAYLOAD"
}

@test "identite absente + compte forge connu : DRIFT qui nomme la consequence" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'check_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT"* ]]
  [[ "$output" == *"aucun compte"* ]]
  [[ "$output" == *"avatar"* ]]
}

@test "apply pose le nom ET l'email du COMPTE FORGE" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ"* ]]
  run git config --global --get user.email
  [ "$output" = "lord@zurp.xyz" ]
  run git config --global --get user.name
  [ "$output" = "Lord Zurp" ]
}

@test "un compte forge SANS full_name retombe sur le login, jamais sur du vide" {
  account "" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  run git config --global --get user.name
  [ "$output" = "$(id -un)" ]
}

@test "SEED-ONCE : une identite deja posee n'est jamais reecrite" {
  git config --global user.name "Le Choix De L Humain"
  git config --global user.email "moi@ailleurs.net"
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'apply_git_identity'
  [ "$status" -eq 0 ]
  [[ "$output" != *"POSÉ"* ]]
  run git config --global --get user.email
  [ "$output" = "moi@ailleurs.net" ]
}

@test "identite posee : la sonde la NOMME au lieu de se taire" {
  git config --global user.email "moi@ailleurs.net"
  run_fn 'check_git_identity'
  [[ "$output" == *"OK"* ]]
  [[ "$output" == *"moi@ailleurs.net"* ]]
}

@test "PAS de compte forge : MUET des deux cotes — ce fait appartient a 63-forge-tokens" {
  # Le cas de `root` sur un vrai conteneur. Deux voix sur un meme fait divergent le jour ou l'une
  # des deux change ; `63-forge-tokens` rapporte deja « compte forge absent pour « X » ».
  echo '{"errors":["user does not exist"]}' > "$FORGE_PAYLOAD"
  run_fn 'check_git_identity'
  [ -z "$output" ]
  run_fn 'apply_git_identity'
  [ -z "$output" ]
  run git config --global --get user.email
  [ "$status" -ne 0 ]
}

@test "forge injoignable : rien n'est invente, le passage suivant la trouvera" {
  account "Lord Zurp" "lord@zurp.xyz"
  run_fn 'FORGE_BASE_URL=""; apply_git_identity'
  [ "$status" -eq 0 ]
  run git config --global --get user.email
  [ "$status" -ne 0 ]
}

@test "TEMOIN STRUCTUREL : l'entrypoint ne pose plus d'identite git" {
  # La regression exacte : un bloc d'identite dans l'entrypoint vise UN compte — celui de l'entree
  # du conteneur — et rate par construction tout humain enrole apres le boot.
  EP="$BATS_TEST_DIRNAME/../../../services/container/boot.sh"
  refute grep -qE '^\s*su - "\$LCARS_[A-Z]+" -c "git config' "$EP"
  refute grep -q 'LCARS_ADMIRAL_EMAIL' <(grep -v '^#' "$EP")
}

# ─── L'ADRESSE DE LA FORGE CONVERGE, ELLE NE S'INSTRUIT PLUS ────────────────────────────────────
#
# Mesure du 2026-08-22, WSL neuve. Le seed de `fleet.env` est SEED-ONCE : la premiere install de
# cette machine l'a seme pendant que `48-forge-host` echouait, donc SANS `FORGE_BASE_URL`. Aux
# passages suivants la forge existait et l'URL etait connue — le fichier n'etait jamais complete.
#
# Un `p_warn` ne baisse aucun verdict : `70-human` rendait « converge », puis `75-projects` echouait
# sur `{:config, {:missing, :base_url}}` — un message qui ne nomme pas sa cause.
#
# Le module portait DEJA l'argument, applique au jeton systeme : « une cle ABSENTE n'est pas un
# choix ; une cle PRESENTE en est un, et celui-la on n'y touche jamais ». L'asymetrie entre les deux
# cles n'etait pas un arbitrage, c'etait un oubli.

@test "l'adresse de la forge se CABLE quand elle est connue et absente du fichier" {
  code() { grep -vE '^\s*#' "$SRC"; }
  code | grep -q 'FORGE_BASE_URL=\$FORGE_BASE_URL'
  # la garde est bien « absente ET connue », jamais « ecrase »
  code | grep -q "! grep -q '\^FORGE_BASE_URL=' \"\$ENV_FILE\""
  code | grep -q 'FORGE_BASE_URL" \]\]'
}

@test "une cle PRESENTE n'est jamais reecrite — c'est un choix de l'humain" {
  # Le module ne doit porter AUCUN sed/awk qui remplace une ligne FORGE_BASE_URL existante : la
  # convergence porte sur le trou, pas sur la decision.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  refute grep -qE "sed .*FORGE_BASE_URL|s\|\^FORGE_BASE_URL" <<<"$code"
}

@test "URL inconnue ET cle absente = DRIFT, jamais un warn qui laisse le verdict vert" {
  # C'est ce qui a coute : `p_warn` ne pese sur rien, donc l'apply rendait vert sur un etat ou
  # `fleet start` refuse, et le module suivant tombait sans nommer la cause.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  grep -q 'p_drift "fleet.env sans FORGE_BASE_URL' <<<"$code"
  refute grep -q 'p_warn "fleet.env sans FORGE_BASE_URL' <<<"$code"
}

@test "les deux cles derivees suivent la MEME regle — jeton et adresse" {
  # Elles vivent dans le meme fichier, viennent toutes deux du provisionnement, et sont toutes deux
  # inutilisables si absentes. Une seule des deux convergeait.
  local code; code="$(grep -vE '^\s*#' "$SRC")"
  grep -q 'FORGE_TOKEN_FILE=\$LCARS_SYSTEM_TOKEN_FILE' <<<"$code"
  grep -q 'FORGE_BASE_URL=\$FORGE_BASE_URL' <<<"$code"
}

# ─── LE GARDE-FOU D'ECRITURE DES AGENTS ─────────────────────────────────────────────────────────
#
# ⚠ CES TEMOINS POSENT LEUR PROPRE `HOME_DIR`, ET C'EST OBLIGATOIRE. Le module le derive de
# `human_home()`, qui lit `getent passwd` : le VRAI home de qui joue les tests. Un temoin qui
# oublierait cette ligne ferait fusionner le module dans le `~/.claude/settings.json` de son
# auteur. Mesure du 2026-08-22, meme classe : un decor qui n'avait pas pose `HOME` a fait ecrire
# une doublure d'installeur a travers un symlink, et tronquer un binaire de 328 Mo.
sandbox() { # sandbox <expr> — joue <expr> avec un home jetable
  run_fn "HOME_DIR=\"\$BATS_TEST_TMPDIR/agent\"; CLAUDE_SETTINGS=\"\$HOME_DIR/.claude/settings.json\"; mkdir -p \"\$HOME_DIR\"; $1"
}

@test "garde-fou : un home SANS settings.json en recoit un, avec le bloc canonique" {
  sandbox 'apply_automode'
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSÉ"* ]]
  # Le bloc pose EST le fichier canonique, pas une copie qui lui ressemble.
  local pose; pose="$(jq -S -c '.autoMode | {hard_deny, classifyAllShell}' "$BATS_TEST_TMPDIR/agent/.claude/settings.json")"
  [ -n "$pose" ]
  [ "$pose" = "$(jq -S -c '{hard_deny, classifyAllShell}' "$BATS_TEST_DIRNAME/../../../services/agent/claude-automode.json")" ]

  # ⚠ ET LA FORME DU BLOC, parce que l'egalite ci-dessus est vraie QUOI QUE DISE la source : elle
  # mesure la plomberie. Un fichier canonique vide ou reduit a `{}` la laisserait verte, et chaque
  # agent recevrait un garde-fou qui n'interdit rien. On epingle la structure — pas la prose de la
  # regle, qui est une politique et doit pouvoir se reformuler sans casser un temoin.
  local f="$BATS_TEST_TMPDIR/agent/.claude/settings.json"
  [ "$(jq -r '.autoMode.classifyAllShell' "$f")" = "true" ]
  [ "$(jq -r '.autoMode.hard_deny | length' "$f")" -ge 2 ]
  [ "$(jq -r '.autoMode.hard_deny[0]' "$f")" = '$defaults' ]
}

@test "garde-fou : les clefs de l'humain SURVIVENT — on pose une regle, on ne reconfigure personne" {
  mkdir -p "$BATS_TEST_TMPDIR/agent/.claude"
  cat > "$BATS_TEST_TMPDIR/agent/.claude/settings.json" <<'JSON'
{"theme":"dark","statusLine":{"type":"command","command":"le mien"},
 "autoMode":{"soft_deny":["a moi"],"environment":["a moi aussi"]}}
JSON
  sandbox 'apply_automode'
  [ "$status" -eq 0 ]
  local f="$BATS_TEST_TMPDIR/agent/.claude/settings.json"
  # Ce qui etait la est encore la, jusque DANS autoMode : la fusion vise deux clefs, pas le bloc.
  [ "$(jq -r '.theme' "$f")" = "dark" ]
  [ "$(jq -r '.statusLine.command' "$f")" = "le mien" ]
  [ "$(jq -r '.autoMode.soft_deny[0]' "$f")" = "a moi" ]
  [ "$(jq -r '.autoMode.environment[0]' "$f")" = "a moi aussi" ]
  [ "$(jq -r '.autoMode.classifyAllShell' "$f")" = "true" ]
}

@test "garde-fou : rejoue, il ne re-pose RIEN — une convergence n'est pas une reecriture" {
  sandbox 'apply_automode'
  [ "$status" -eq 0 ]
  local before; before="$(cat "$BATS_TEST_TMPDIR/agent/.claude/settings.json")"
  sandbox 'apply_automode'
  [ "$status" -eq 0 ]
  # Pas de POSÉ au second tour, et le fichier est identique a l'octet.
  [[ "$output" != *"POSÉ"* ]]
  [ "$before" = "$(cat "$BATS_TEST_TMPDIR/agent/.claude/settings.json")" ]
}

@test "garde-fou : un settings.json ILLISIBLE est un ECHEC, jamais un ecrasement" {
  # Le pire des deux : detruire une configuration que son humain peut encore reparer, pour poser
  # une regle. Le module le DIT et ne touche a rien.
  mkdir -p "$BATS_TEST_TMPDIR/agent/.claude"
  printf '{ ceci n est pas du json\n' > "$BATS_TEST_TMPDIR/agent/.claude/settings.json"
  local before; before="$(cat "$BATS_TEST_TMPDIR/agent/.claude/settings.json")"
  sandbox 'apply_automode'
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
  [ "$before" = "$(cat "$BATS_TEST_TMPDIR/agent/.claude/settings.json")" ]
}
