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
  # ⚠ LE JETON NE SE LIT PLUS DANS UN FICHIER, IL SE DEMANDE. La fixture n'est donc plus un fichier
  # de jeton mais une doublure du CLIENT d'autorite — c'est par la que le skill obtient son
  # credential depuis que le groupe `fleet` a cesse d'ouvrir `/home/private`.
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask-ok"
  printf '#!/usr/bin/env bash\nprintf "TOK\\n"\n' > "$LCARS_AUTHORITY_ASK_BIN"
  chmod +x "$LCARS_AUTHORITY_ASK_BIN"

  run "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"#12"* ]]
  [[ "$output" == *"pod en echec"* ]]
  [[ "$output" == *"!7"* ]]
  [[ "$output" == *"[toolchain] python"* ]]
}

@test "list.sh: pas de jeton => refus type, pas une liste vide" {
  export LCARS_FORGE_URL="http://forge.test"
  # Le client refuse en 1, sa cause sur stderr — exactement ce que fait le vrai quand la forge dit
  # non. Le skill doit MOURIR dessus, jamais rendre deux listes vides qu'un lecteur prendrait pour
  # « rien a traiter » : une boite de reception vide et une boite de reception inaccessible se
  # ressemblent a l'ecran et ne veulent pas dire la meme chose.
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/ask-ko"
  printf '#!/usr/bin/env bash\necho "autorite: refus de fixture" >&2\nexit 1\n' > "$LCARS_AUTHORITY_ASK_BIN"
  chmod +x "$LCARS_AUTHORITY_ASK_BIN"

  run "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"pas de jeton de forge"* ]]
}

@test "list.sh: client d'autorite ABSENT => refus qui le NOMME, pas « commande introuvable »" {
  export LCARS_FORGE_URL="http://forge.test"
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/jamais-pose"
  run "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"client d'autorite absent"* ]]
}

@test "list.sh: le jeton SYSTEME, jamais le master — deux lectures publiques n'ont pas d'autorite" {
  # ⚠ MESURE DU 2026-08-23 SUR UNE FORGE VIVANTE : `fleet/lcars` est `private=false, internal=false`
  # et ses deux points d'entree (`issues`, `pulls`) repondent 200 EN ANONYME. Ce script tenait le
  # jeton master parce qu'il etait la, pas parce que son geste l'exige — et le tenir imposait que le
  # master reste lisible par un humain, c'est-a-dire exactement l'ACL qu'on retire.
  local src="$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  # `run` + test nu : une `! grep` non terminale serait exemptee de `set -e`, donc inerte.
  run grep -c 'MASTER_TOKEN' "$src"
  [ "$output" -eq 0 ]
  run grep -c 'forge-master.token' "$src"
  [ "$output" -eq 0 ]
  # ⚠ `gitea_token` A QUITTE L'ASSERTION AVEC LE FICHIER QU'IL NOMMAIT. Ce skill ne construit plus
  # AUCUN chemin de jeton : il demande un COMPTE au service d'autorite. Ce qui reste a epingler est
  # l'identite — c'est bien le compte systeme, jamais le master — et elle se lit sur le nom du
  # compte, pas sur un nom de fichier. Le second `grep` est la contrepartie : plus aucune trace du
  # repertoire prive, sinon l'assertion du haut passerait sur un script qui lit encore.
  grep -q 'SYSTEM_ACCOUNT' "$src"
  run grep -c 'PRIVATE_DIR' "$src"
  [ "$output" -eq 0 ]
  # Et le skill ne PROMET plus un privilege de siege, qui n'existe pas.
  ! grep -q 'master token' "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/SKILL.md"
}

# ⚠ LE TEMOIN QUI GARDE LA CORRECTION AU PASSAGE. L'en-tete d'authentification etait construit dans
# un tableau passe a `curl` en ARGV : le jeton systeme etait donc lisible dans `/proc/<pid>/cmdline`
# par n'importe quel process de la boite, pendant toute la duree de l'appel. Fermer un fichier
# `0640` et laisser le secret dans une ligne de commande annulerait le geste au moment ou il
# s'exerce. `-K -` le fait passer par un tube.
@test "list.sh: le jeton ne passe JAMAIS en argv de curl" {
  local src="$LCARS_ADMIRAL_SKILLS_SRC/system-issues/list.sh"
  grep -q 'curl -sSf -m 15 -K -' "$src"
  run grep -c -- '-H "Authorization' "$src"
  [ "$output" -eq 0 ]
}
