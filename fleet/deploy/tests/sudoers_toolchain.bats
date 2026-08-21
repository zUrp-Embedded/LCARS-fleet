#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/sudoers_toolchain.bats
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: bats tests for 45-sudoers-toolchain — le cablage systeme du rail toolchain
#
# CE QUE CES TEMOINS TIENNENT, en trois familles :
#   - le SUDOERS : un binaire nomme, pose par write_atomic, REFUSE si visudo dit non — un
#     sudoers.d invalide casse TOUT sudo, pas seulement celui-ci ;
#   - la PROJECTION du siege : keyee sur l'UID (jamais un nom), inconditionnelle (un login qui
#     change ecrase l'ancien), gardee sur le magasin (var vide => AUCUNE ecriture — sinon
#     `/state/pilot.assignee` naitrait a la racine, jamais lu) ;
#   - le module est charge SANS son dispatch, patron `human_git_identity.bats`.

setup() {
  SRC="$BATS_TEST_DIRNAME/../modules.d/45-sudoers-toolchain.sh"
  [ -f "$SRC" ]
  export LCARS_ADMIRAL_SKILLS_SRC="$BATS_TEST_DIRNAME/../admiral/skills"
  # ⚠ SANS cette couture, la branche skill ecrirait dans le VRAI ~/.claude de qui joue les tests.
  export LCARS_SIEGE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$LCARS_SIEGE_HOME"

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=45-sudoers-toolchain
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"   # un chgrp qui marche sous l'uid des tests

  export LCARS_SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"; mkdir -p "$LCARS_SUDOERS_DIR"
  export LCARS_TOOLCHAIN_RUN_STATE="$BATS_TEST_TMPDIR/run-state"
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store"; mkdir -p "$LCARS_STORE_ROOT"
  # Le siege des tests, c'est NOUS : la cle est l'uid, on la fait coincider.
  export LCARS_SYSADMIN_UID="$(id -u)"

  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export PATH="$BIN:$PATH"

  MOD="$BATS_TEST_TMPDIR/mod.sh"
  sed '/^case "${1:?usage/,$d' "$SRC" > "$MOD"

  # ⚠ LE DECOR POSSEDE SON DOSSIER RUNTIME, meme motif que son `sudoers.d` et son store ci-dessus.
  # Le module prend un verrou, et `prov_lock_path` le veut dans
  # `${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars` pour un appelant non-root — REFUS si le parent
  # manque (6-130 : pas de repli dans un dossier partage). Un compte de service n'a PAS de session
  # logind : mesure du 2026-08-20, `/run/user/1001` n'existe par aucune voie sur le poste natif.
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
}

run_apply() { run bash -c ". '$MOD'; apply"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  grep -q "^# SOURCE:" "$SRC"; grep -q "^# AUTHOR:" "$SRC"
  grep -q "^# STARDATE:" "$SRC"; grep -q "^# STATUS:" "$SRC"
}

@test "sudoers: pose, contenu exact, mode 0440" {
  run_apply
  [[ "$status" -eq 0 ]]
  local f="$LCARS_SUDOERS_DIR/lcars-toolchain"
  [[ -f "$f" ]]
  grep -qx "%$PROV_FLEET_GROUP ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge" "$f"
  [[ "$(stat -c %a "$f")" == "440" ]]
}

@test "sudoers: un contenu refuse par visudo N'EST PAS pose" {
  # visudo double en tete de PATH : refuse tout. Si le module posait quand meme, sudo entier
  # serait casse en prod — c'est le temoin de l'ordre valide-PUIS-pose.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/visudo"; chmod +x "$BIN/visudo"
  run_apply
  [[ "$status" -ne 0 ]]
  [[ ! -f "$LCARS_SUDOERS_DIR/lcars-toolchain" ]]
}

@test "sudoers: un REFUS en cours de mise a jour laisse l'ANCIEN fichier intact (atomicite observable)" {
  # ⚠ La v1 de ce temoin cherchait des artefacts .prov.* survivants — write_atomic les nettoie sur
  # TOUS ses chemins, et une redirection nue n'en laisse pas non plus : il etait vert sur
  # l'implementation qu'il pretendait interdire (audit). La propriete OBSERVABLE est celle-ci :
  # un sudoers valide est en place, la mise a jour est REFUSEE (visudo) => l'ancien fichier est
  # toujours la, OCTET POUR OCTET. Une ecriture en place l'aurait tronque ou remplace avant le
  # refus — la machine ou plus personne ne passe root (cicatrice provision-lib.sh:18).
  run_apply
  [[ "$status" -eq 0 ]]
  local before; before="$(cat "$LCARS_SUDOERS_DIR/lcars-toolchain")"

  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/visudo"; chmod +x "$BIN/visudo"
  export LCARS_TOOLCHAIN_CONVERGE_BIN="/usr/local/bin/autre-binaire"
  run_apply
  [[ "$status" -ne 0 ]]
  [[ "$(cat "$LCARS_SUDOERS_DIR/lcars-toolchain")" == "$before" ]]
}

@test "etat conteneur: le repertoire du marqueur existe en 2775" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ -d "$LCARS_TOOLCHAIN_RUN_STATE" ]]
  [[ "$(stat -c %a "$LCARS_TOOLCHAIN_RUN_STATE")" == "2775" ]]
}

@test "projection: le login du siege atterrit dans pilot.assignee" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/pilot.assignee")" == "$PROV_HUMAN" ]]
}

@test "projection: REECRITURE inconditionnelle — un login mort ne survit pas au boot suivant" {
  mkdir -p "$LCARS_STORE_ROOT/state"
  printf 'ancien-login\n' > "$LCARS_STORE_ROOT/state/pilot.assignee"
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$LCARS_STORE_ROOT/state/pilot.assignee")" == "$PROV_HUMAN" ]]
}

@test "projection: KEYEE SUR L'UID — un humain qui n'est pas le siege n'ecrit RIEN" {
  export LCARS_SYSADMIN_UID="99999"   # personne
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "$LCARS_STORE_ROOT/state/pilot.assignee" ]]
}

@test "projection: LCARS_STORE_ROOT vide => AUCUNE ecriture, nulle part" {
  # Sans la garde, bash etend en /state/pilot.assignee : cree a la racine par root en prod,
  # jamais lu par personne — le mode de panne de 02 §3.1.
  export LCARS_STORE_ROOT=""
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "/state/pilot.assignee" ]]
  [[ "$output" == *"inerte"* ]]
}

@test "projection: magasin non monte (var posee, dossier absent) => inerte, dit, rc 0" {
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/nulle-part"
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"inerte"* ]]
}

@test "check: drift quand le sudoers manque, OK quand tout est pose" {
  run bash -c ". '$MOD'; check"
  [[ "$output" == *"DRIFT"* ]]
  run_apply
  run bash -c ". '$MOD'; check"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"sudoers etroit absent"* ]]
}

@test "skill: POSE chez le SIEGE — SKILL.md + list.sh executables dans SON ~/.claude" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"skill system-issues pose"* ]]
  [ -f "$LCARS_SIEGE_HOME/.claude/skills/system-issues/SKILL.md" ]
  [ -x "$LCARS_SIEGE_HOME/.claude/skills/system-issues/list.sh" ]
}

@test "skill: la source se trouve AUSSI hors image — le rail poste n'a pas /opt/lcars" {
  # `/opt/lcars/admiral-skills` est un chemin d'IMAGE (Dockerfile COPY). Sur le rail poste il
  # n'existe pas, et le module derivait en accusant l'image — « image sans les sources admiral ? » —
  # sur une machine qui n'est pas une image. Mesure du 2026-08-21, install a froid sur machine
  # dediee. Le siege n'y recevait jamais son skill, et le message envoyait chercher la faute dans
  # un artefact absent.
  unset LCARS_ADMIRAL_SKILLS_SRC
  run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; echo \"\$SKILL_SRC\""
  [ "$status" -eq 0 ]
  # Sur la machine qui joue ce test, /opt/lcars n'existe pas : la source est donc celle du DEPOT,
  # et elle porte reellement le skill (sinon ce temoin ne prouverait qu'un chemin bien forme).
  [[ "$output" == */fleet/deploy/admiral/skills ]]
  [ -f "$output/system-issues/SKILL.md" ]
}

@test "skill: le don a l'humain ne NOMME jamais de groupe — un groupe prive n'est pas garanti" {
  # CE QUE CE TEMOIN FERME. Le module donnait ses fichiers en `<humain>:<humain>` : une hypothese de
  # groupe prive homonyme, vraie seulement la ou `USERGROUPS_ENAB yes` en cree un a l'inscription du
  # compte. Un humain de la fleet dont le groupe primaire est `fleet` n'a AUCUN groupe a son nom, et
  # l'appel meurt sur `chown: invalid group`. Mesure du 2026-08-20 : neuf temoins rouges sur le
  # poste natif, verts ici, pour la seule raison que le compte local porte un groupe prive.
  #
  # ⚠ ET C'EST POURQUOI ON SONDE `chown` PLUTOT QUE LE RESULTAT. Sur la machine qui joue ce test le
  # compte a probablement un groupe prive — donc les deux formes REUSSIRAIENT, et un temoin qui
  # regarde le fichier pose ne verrait aucune difference. Ce qui distingue les deux formes n'est
  # observable que dans l'ARGUMENT passe a chown.
  cat > "$BIN/chown" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$BATS_TEST_TMPDIR/chown.argv"
exit 0
FAKE
  chmod 0755 "$BIN/chown"
  : > "$BATS_TEST_TMPDIR/chown.argv"

  run_apply
  [[ "$status" -eq 0 ]]

  # Au moins un don a eu lieu, sinon ce temoin ne mesure rien.
  [ -s "$BATS_TEST_TMPDIR/chown.argv" ]
  # Aucune specification ne nomme un groupe apres le deux-points.
  run grep -cE ":[^[:space:]]+$" "$BATS_TEST_TMPDIR/chown.argv"
  [ "$output" = "0" ]
  # …et la forme attendue est bien presente : `<humain>:`, le groupe de CONNEXION de l'humain.
  grep -qx -- "$PROV_HUMAN:" "$BATS_TEST_TMPDIR/chown.argv"
}

@test "skill: PAS pose quand l'humain n'est pas le siege (la branche uid ferme tout le bloc 3+4)" {
  export LCARS_SYSADMIN_UID="99999"
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "$LCARS_SIEGE_HOME/.claude" ]]
}

@test "list.sh: les deux listes, avec curl et jq stubes — et RIEN d'autre que de la lecture" {
  BIN="$BATS_TEST_TMPDIR/lbin"; mkdir -p "$BIN"
  cat > "$BIN/curl" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  *issues*) echo '[{"number":12,"created_at":"2026-08-19T00:00:00Z","title":"pod en echec"}]'; exit 0;;
  *pulls*)  echo '[{"number":7,"created_at":"2026-08-19T00:00:00Z","title":"[toolchain] python","base":{"ref":"tool_request"}}]'; exit 0;;
esac; done
exit 1
EOS
  chmod +x "$BIN/curl"
  export PATH="$BIN:$PATH"
  export LCARS_FORGE_URL="http://forge.test"
  export LCARS_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/tok"; printf 'TOK\n' > "$LCARS_MASTER_TOKEN_FILE"

  run "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"#12"* ]]
  [[ "$output" == *"pod en echec"* ]]
  [[ "$output" == *"!7"* ]]
  [[ "$output" == *"[toolchain] python"* ]]
}

@test "list.sh: token illisible => refus type, pas une liste vide" {
  export LCARS_FORGE_URL="http://forge.test"
  export LCARS_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/absent"
  run "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"master token illisible"* ]]
}
