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

# ⚠ SC2030/SC2031 : CHAQUE `@test` DE BATS EST UN SOUS-SHELL, et c'est la propriete qu'on veut —
# un test ne teinte pas le suivant. Que les variables posees dans un test soient « locales » est
# l'isolation, pas une fuite.
# shellcheck disable=SC2030,SC2031

load ../refute

setup() {
  SRC="$BATS_TEST_DIRNAME/../../modules.d/45-sudoers-toolchain.sh"
  [ -f "$SRC" ]
  export LCARS_ADMIRAL_SKILLS_SRC="$BATS_TEST_DIRNAME/../../../services/admiral/skills"
  # ⚠ SANS cette couture, la branche skill ecrirait dans le VRAI ~/.claude de qui joue les tests.
  export LCARS_SIEGE_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$LCARS_SIEGE_HOME"

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export PROVISION_MODULE=45-sudoers-toolchain
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"   # un chgrp qui marche sous l'uid des tests

  export LCARS_SUDOERS_DIR="$BATS_TEST_TMPDIR/sudoers.d"; mkdir -p "$LCARS_SUDOERS_DIR"
  export LCARS_TOOLCHAIN_RUN_STATE="$BATS_TEST_TMPDIR/run-state"
  export LCARS_STORE_ROOT="$BATS_TEST_TMPDIR/store"; mkdir -p "$LCARS_STORE_ROOT"
  # Le siege des tests, c'est NOUS : la cle est l'uid, on la fait coincider.
  export LCARS_SYSADMIN_UID
  LCARS_SYSADMIN_UID="$(id -u)"

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

# ─── LE SUDOERS EST RETIRE, ET CES TEMOINS ONT CHANGE DE SIGNE ──────────────────────────────────
#
# Ils epinglaient la POSE de `%fleet ALL=(root) NOPASSWD:` — sa forme exacte, son mode, l'atomicite
# de sa mise a jour. Tous verts, et tous sur un objet qui etait le lien le plus fin du systeme : un
# chemin `groupe -> root` direct, sur un groupe que le convergeur repeuple depuis la forge toutes
# les trente secondes.
#
# Le geste passe par `toolchain.sock`. Ce qui se garde ici est desormais l'ABSENCE — et c'est un
# contrat plus dur que la pose, parce qu'il porte sur les boites DEJA provisionnees.

@test "sudoers: l'apply RETIRE la regle sur une boite qui la porte encore" {
  # ⚠ LE TEMOIN QUI COMPTE LE PLUS DE CETTE PHASE. Cesser de POSER ne retire rien : le NOPASSWD
  # survivrait au chantier qui le supprime, sur chaque machine deja convergee, indefiniment et sans
  # qu'une ligne le dise. C'est mot pour mot la maladie que ce module cite a son point 3 — « sans
  # convergence, un admin demis garde son droit indefiniment ».
  local f="$LCARS_SUDOERS_DIR/lcars-toolchain"
  printf '%%%s ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge\n' "$PROV_FLEET_GROUP" > "$f"
  [[ -f "$f" ]]

  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "$f" ]]
}

@test "sudoers: le check DIT qu'il reste un chemin groupe → root, il ne le constate pas en silence" {
  local f="$LCARS_SUDOERS_DIR/lcars-toolchain"
  printf '%%%s ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge\n' "$PROV_FLEET_GROUP" > "$f"

  run bash -c ". '$MOD'; check"
  [[ "$output" == *"groupe → root"* ]]
  [[ "$output" == *"toolchain.sock"* ]]
}

@test "sudoers: sur une boite propre, l'apply ne pose RIEN et reste vert" {
  # LE TEMOIN DU TEMOIN : sans lui, un module qui echouerait sur l'absence du fichier passerait le
  # premier test (qui, lui, en pose un) et casserait chaque apply d'une boite deja saine.
  [[ ! -e "$LCARS_SUDOERS_DIR/lcars-toolchain" ]]
  run_apply
  [[ "$status" -eq 0 ]]
  [[ ! -e "$LCARS_SUDOERS_DIR/lcars-toolchain" ]]
}

@test "sudoers: plus AUCUNE ligne de CODE ne construit une regle NOPASSWD" {
  # ⚠ ON MESURE LE CODE, PAS LA PROSE, et ma premiere ecriture comptait les deux. Les cicatrices de
  # ce module NOMMENT la regle retiree — c'est leur metier, et un temoin qui les compterait
  # interdirait d'expliquer ce qu'on a retire. La prochaine session referait le defaut faute de
  # savoir pourquoi c'en etait un.
  #
  # Le nom du convergeur, lui, n'a plus rien a faire ici : le seul a l'invoquer est
  # `lcars-privileged`, qui le connait chez lui. Une seconde autorite sur un chemin est celle qu'on
  # ne relit pas, et c'est elle qui ment.
  # ⚠ ET ON CHERCHE LA SYNTAXE D'UNE REGLE, PAS LE MOT. Ma premiere ecriture comptait « NOPASSWD »
  # et accusait le MESSAGE DE REFUS du module — « le groupe garde un NOPASSWD root » — qui est
  # exactement la phrase qu'un operateur doit lire. Un temoin qui interdit de nommer le danger
  # pousse a l'ecrire moins clairement. Ce qui construit une regle, c'est `ALL=(root)`.
  local n
  n="$(sed 's/#.*//' "$SRC" | grep -cE 'ALL=\(root\)' || true)"
  [ "$n" -eq 0 ] || { sed 's/#.*//' "$SRC" | grep -nE 'ALL=\(root\)' >&2; return 1; }
  # Et rien n'ECRIT dans le fichier de sudoers : la seule chose qui lui arrive est `rm`.
  n="$(sed 's/#.*//' "$SRC" | grep -cE '(write_atomic|install|>|tee).*SUDOERS_FILE' || true)"
  [ "$n" -eq 0 ] || { sed 's/#.*//' "$SRC" | grep -nE 'SUDOERS_FILE' >&2; return 1; }
  n="$(sed 's/#.*//' "$SRC" | grep -cE 'LCARS_TOOLCHAIN_CONVERGE_BIN' || true)"
  [ "$n" -eq 0 ]
}

@test "etat conteneur: le repertoire du marqueur existe en 2775" {
  run_apply
  [[ "$status" -eq 0 ]]
  [[ -d "$LCARS_TOOLCHAIN_RUN_STATE" ]]
  [[ "$(stat -c %a "$LCARS_TOOLCHAIN_RUN_STATE")" == "2775" ]]
}

# ─── LE VECTEUR 6-131, MESURE PLUTOT QUE DECRIT ─────────────────────────────────────────────────
#
# ⚠ CE MODULE CREUSAIT EN `install -d` NU, ET `install -d` SUIT LES LIENS. La garde
# `prov_refuse_symlink_path` vit dans `ensure_dir` pour exactement ca : quelqu'un pose un lien dans
# un composant du chemin, et le prochain apply en ROOT chmode/chowne la CIBLE. Trois sites de ce
# module et un de `55-deck-oidc` contournaient la garde en n'appelant pas la lib.
#
# UN TEMOIN DE TEXTE NE SUFFIT PAS ICI — il epinglerait l'orthographe d'un appel. On pose un vrai
# lien vers une vraie cible, on joue l'apply, et on regarde si la cible a bouge.
@test "etat conteneur: un LIEN a la place du repertoire est REFUSE, et la cible ne bouge pas" {
  local cible="$BATS_TEST_TMPDIR/cible-innocente"
  mkdir -p "$cible"; chmod 0700 "$cible"
  rm -rf "$LCARS_TOOLCHAIN_RUN_STATE"
  ln -s "$cible" "$LCARS_TOOLCHAIN_RUN_STATE"

  run_apply
  # LA CIBLE EST INTACTE — la seule assertion qui compte. Son mode aurait ete reecrit en 2775 et son
  # groupe change si le lien avait ete suivi.
  [[ "$(stat -c %a "$cible")" == "700" ]]
  # Et le lien est toujours un lien : on ne l'a pas remplace en douce non plus.
  [[ -L "$LCARS_TOOLCHAIN_RUN_STATE" ]]
}

@test "skill: un LIEN pose dans le home du siege ne fait pas chowner sa cible" {
  # Le site le plus expose du module : root creuse `~/.claude/skills/...` dans un home que son
  # proprietaire controle, puis chowne. La portee est etroite — le siege a deja root — mais c'est le
  # motif que la lib ferme, et une garde qui ne vaut que quand l'attaquant n'a rien a gagner n'en
  # est pas une.
  local cible="$BATS_TEST_TMPDIR/etc-innocent"
  mkdir -p "$cible"; chmod 0700 "$cible"
  rm -rf "$LCARS_SIEGE_HOME/.claude"
  ln -s "$cible" "$LCARS_SIEGE_HOME/.claude"

  run_apply
  [[ "$(stat -c %a "$cible")" == "700" ]]
  [[ -L "$LCARS_SIEGE_HOME/.claude" ]]
  # ⚠ ET RIEN N'EST ECRIT DANS LA CIBLE. Premiere ecriture du correctif : `|| skdst=""` — les deux
  # `write_atomic` d'apres devenaient `/SKILL.md` et `/list.sh`, en ROOT, A LA RACINE. Le bloc doit
  # SAUTER, pas se replier sur un autre chemin.
  [[ -z "$(ls -A "$cible")" ]]
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

@test "skill: UN SEUL chemin de source, et il vaut sur les DEUX rails" {
  # ⚠ IL Y EN AVAIT DEUX, ET LE MODULE CHOISISSAIT ENTRE EUX. L'image posait le skill en
  # `/opt/lcars/admiral-skills`, le depot le portait sous `deploy/admiral/skills` : le module
  # essayait le premier, retombait sur le second. Ce repli ne corrigeait pas la divergence, il la
  # contournait — sur le rail poste le module derivait en accusant l'image (« image sans les sources
  # admiral ? ») sur une machine qui n'est pas une image, et le siege n'y recevait jamais son skill
  # (mesure du 2026-08-21, install a froid sur machine dediee). Le message envoyait chercher la
  # faute dans un artefact absent.
  #
  # Le skill vit maintenant sous `fleet/services/admiral/skills`, ou `EMBEDDED` et le `COPY` de
  # l'image le posent au MEME endroit. Ce qui se mesure ici n'est donc plus « il existe un repli »
  # mais « il n'y a plus rien entre quoi choisir » : un chemin, derive de `repo_root()`, et il
  # porte reellement le skill — sinon ce temoin ne prouverait qu'une chaine bien formee.
  unset LCARS_ADMIRAL_SKILLS_SRC
  run bash -c "set -euo pipefail; source '$MOD' >/dev/null 2>&1; echo \"\$SKILL_SRC\""
  [ "$status" -eq 0 ]
  # Sur la machine qui joue ce test, /opt/lcars n'existe pas : la source est donc celle du DEPOT,
  # et elle porte reellement le skill (sinon ce temoin ne prouverait qu'un chemin bien forme).
  [[ "$output" == */fleet/services/admiral/skills ]]
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
  # credential depuis que le groupe `fleet` a cesse d'ouvrir `/opt/lcars/var/tokens`.
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
  refute grep -q 'master token' "$LCARS_ADMIRAL_SKILLS_SRC/system-issues/SKILL.md"
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
