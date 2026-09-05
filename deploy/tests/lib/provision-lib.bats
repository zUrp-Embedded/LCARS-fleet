#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/provision-lib.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for lib/provision-lib.sh — the lib's one promise is "never lie green"
#
# Every scenario runs in a FRESH bash process with `set -euo pipefail`, exactly like a module
# (modules are separate processes sourcing the lib — never a shared namespace). What is proven
# here is the counter/verdict CONTRACT, i.e. the three lies killed by the conformance pass:
#   B1  run_quiet failure without PROV_FAILED  → `run_quiet x || verdict_apply` exited 0 (green lie)
#   B3  write_atomic on the right side of a pipe → counters died in the subshell (green lie)
#   B5  human_home under pipefail on unknown user → silent abort BEFORE the caller's p_fail guard
# The real filesystem effects (atomic write, managed block replacement) are asserted on tmpdirs.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  # ⚠ LE DECOR POSSEDE SON ENVIRONNEMENT, ET CE FICHIER ETAIT LE SEUL DU CORPUS A NE PAS LE FAIRE.
  # Mesure du 2026-08-26 : `PROV_VERBOSE=1 bats provision_lib.bats` rend DEUX temoins rouges — ceux
  # qui mesurent la boucle de sonde et le bornage d'ecran de `run_step`, c'est-a-dire la branche NON
  # verbose. Une variable heritee du shell de l'operateur basculait leur sujet sans qu'ils le sachent.
  #
  # Ce n'est pas une regression de `--ok` : l'ancienne branche verbose deversait tout aussi. C'est un
  # temoin qui mesure la MACHINE QUI LE JOUE, exactement ce que ce corpus interdit partout ailleurs —
  # `fleet_human.bats` et `services_units.bats` portent la meme boucle depuis leur premiere version.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]

  # ⚠ LE DECOR POSSEDE SON DOSSIER RUNTIME, comme il possede deja ses tmp. `prov_lock_path` derive
  # `${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars` pour un appelant non-root et REFUSE si le parent
  # n'existe pas — fail-loud deliberé de 6-130 : un verrou privilegie ne vit pas dans un dossier
  # partage, et faute d'emplacement sur on le DIT plutot que de se rabattre ailleurs.
  #
  # OR UN COMPTE DE SERVICE N'A PAS DE SESSION LOGIND. Mesure du 2026-08-20 sur le poste natif :
  # `/run/user/1001` n'existe par AUCUNE voie — ni `sudo -u`, ni `runuser`, ni meme un login ssh.
  # Ces temoins tombaient donc sur « verrou: emplacement sur indisponible » pour un code
  # parfaitement sain, et la faute etait de mesurer la SESSION de qui lance les tests.
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"

  # ⚠ MEME LECON, DEUXIEME VARIABLE, ET CELLE-CI EST ARRIVEE PAR LE HAUT. Ces temoins tournent
  # AUSSI depuis `provision` — `60-deploy` appelle `deploy/lib/deploy-release.sh`, qui joue le gate — et le runner
  # exporte `PROV_SUBSTRATE` (`provision:128`). Un temoin qui declare son substrat sans effacer
  # celui-la mesure donc la machine qui le lance : vert sur un poste WSL, rouge le 2026-08-23 sur
  # `.63` (Linux natif) sur du code identique. Le decor POSSEDE ces deux valeurs ; un test qui en
  # veut une la pose lui-meme, sur la ligne qui la concerne.
  unset PROV_SUBSTRATE LCARS_WSL_NETWORKING_MODE

  # ⚠ LE SIEGE SE LIT DANS UN FICHIER AVANT LA VARIABLE (`prov_seat_uid`), et ce fichier existe sur
  # toute machine provisionnee (MUR I9) : les temoins de la regle d'uid, en bas de ce fichier, posent
  # leur siege par la variable — le canal fichier est ferme ici pour que leur declaration s'applique.
  export LCARS_SEAT_UID_FILE="$BATS_TEST_TMPDIR/aucun-siege-pose/seat.uid"
}

# Helper: run a module-like snippet (fresh bash, module shell options, lib sourced).
module_sh() {
  run bash -c "set -euo pipefail; export PROVISION_MODULE=test-mod; source \"\$LIB\"; $1"
}

# ─── B1 — run_quiet failure MUST count ───────────────────────────────────────────────────────────

@test "B1: run_quiet failure increments PROV_FAILED and keeps the command's rc" {
  module_sh '
    rc=0
    run_quiet bash -c "echo boom-output; exit 3" || rc=$?
    [ "$rc" -eq 3 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  # failure is verbose: the command output is dumped, not swallowed
  [[ "$output" == *boom-output* ]]
}

@test "B1: run_quiet x || verdict_apply exits 1 (the green lie is dead)" {
  module_sh '
    run_quiet false || verdict_apply
    verdict_apply
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
}

@test "B1: run_quiet success stays silent and counts nothing" {
  module_sh '
    run_quiet true
    [ "$PROV_FAILED" -eq 0 ] && [ "$PROV_CHANGED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
}

# ─── B3 — ensure_managed_block: counters live in the CALLER shell ────────────────────────────────

@test "B3: managed block success is SEEN by the caller (PROV_CHANGED > 0)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "managed-line-a"
    [ "$PROV_CHANGED" -ge 1 ]
    grep -q "managed-line-a" "$f"
    grep -q "human line" "$f"
  '
  [ "$status" -eq 0 ]
}

@test "B3: managed block failure is SEEN by the caller (PROV_FAILED > 0, verdict red)" {
  module_sh '
    ensure_managed_block "$BATS_TEST_TMPDIR/no-such-dir/x.conf" testmark 0644 <<< "y" || true
    [ "$PROV_FAILED" -ge 1 ]
    verdict_apply
  '
  [ "$status" -eq 1 ]
}

@test "B3: managed block converges to the CURRENT source (replaced, not append-once)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "old-content"
    ensure_managed_block "$f" testmark 0644 <<< "new-content"
    grep -q "new-content" "$f"
    # ⚠ `&& exit 1`, PAS `! grep`. Ce bloc tourne dans un shell `set -euo pipefail`, et bash exempte
    # d`errexit` toute commande niee par `!` : la ligne s exécutait, echouait, et le script
    # continuait. Mutation du 2026-08-26 — la purge de l ancien bloc cassee dans
    # `ensure_managed_block` — le temoin restait VERT avec l ancien contenu TOUJOURS present. La
    # convergence d un bloc gere n etait donc gardee par rien.
    grep -q "old-content" "$f" && { echo "l ancien contenu a SURVECU a la convergence"; exit 1; }
    [ "$(grep -c "lcars:testmark" "$f")" -eq 2 ]
  '
  [ "$status" -eq 0 ]
}

@test "B3: managed block is idempotent (second identical run changes nothing)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/target.conf"
    printf "human line\n" > "$f"
    ensure_managed_block "$f" testmark 0644 <<< "stable"
    before="$PROV_CHANGED"
    ensure_managed_block "$f" testmark 0644 <<< "stable"
    [ "$PROV_CHANGED" -eq "$before" ]
  '
  [ "$status" -eq 0 ]
}

# ─── B5 — unknown human: empty answer, never a silent abort ──────────────────────────────────────

@test "B5: human_home on unknown user returns empty under set -euo pipefail (no abort)" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    home="$(human_home)"
    [ -z "$home" ]
    echo survived
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *survived* ]]
}

@test "B5: as_human on unknown user reaches its p_fail guard (counted, not aborted)" {
  module_sh '
    export PROV_HUMAN=no-such-user-b5-probe
    as_human true || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"user inconnu"* ]]
}

@test "as_human POSE LE CWD, pas seulement HOME — un cwd illisible casse tout chemin relatif" {
  # ⚠ TEMOIN D'UNE INSTALLATION CASSEE, pas d'une precaution. `as_human` posait HOME/USER/LOGNAME
  # et laissait le REPERTOIRE COURANT de root. Mesure du 2026-08-20 sur un poste natif : la porte
  # `lcars project reconcile`, lancee depuis un `provision apply` en root avec cwd `/root` (0700),
  # rendait vingt lignes de `File operation error: eacces. Target: ./Elixir.Logger.beam` — l'ERTS
  # cherchant ses modules par chemin RELATIF dans un dossier que l'humain ne peut pas lire. Aucune
  # de ces vingt lignes ne nomme le cwd : le diagnostic accuse le release, jamais le repertoire.
  #
  # Le `cd` fait donc partie de l'identite au meme titre que HOME. Ce temoin lit le cwd DEPUIS le
  # process fils, la seule place ou la question se pose.
  # ⚠ LU SUR LA SOURCE, ET C'EST LE SEUL MOYEN. Le defaut ne vit QUE sur la branche root→humain
  # (`runuser`) : quand l'appelant EST deja l'humain, `as_human` execute directement et le cwd est
  # son propre choix, pas un heritage. Exercer la vraie branche demanderait root et un second
  # compte — ce que cette suite ne peut pas fabriquer. Un temoin qui se rabattrait sur la branche
  # directe passerait au vert sans jamais toucher le code fautif : c'est le faux-vert que ce
  # fichier existe pour interdire, alors il lit la forme et le DIT.
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  grep -qE '^\s*\( cd "\$home" && runuser -u "\$PROV_HUMAN"' "$lib"
  # Et le `cd` est dans un SOUS-SHELL : sans les parentheses, le module appelant repartirait avec
  # un cwd change sous lui, ce qui echangerait un defaut contre un autre, plus difficile a voir.
  grep -qE '^\s*\( cd .* \)$' "$lib"
}

# ─── ensure_group / ensure_member : LEUR MOITIE ECRIVANTE N ETAIT JOUEE NULLE PART ──────────────
#
# ⚠ LES DEUX VERBES S EXECUTAIENT DANS LE CORPUS, MAIS JAMAIS LA BRANCHE QUI ECRIT. Le decor de
# `service_accounts.bats` porte des groupes qui EXISTENT deja, donc les deux fonctions y prennent
# toujours leur sortie « rien a faire » : le `groupadd` et le `usermod -aG` n avaient aucune
# couverture. Et leur seul appelant du rail natif, `modules.d/20-groups.sh`, n est joue par aucun
# des .bats du corpus — ses deux mentions y sont des COMMENTAIRES.
#
# CE QUE CA PORTE : `20-groups` est le seul poseur de `lcars-console` sur le rail natif (`groupadd`
# ne parait ailleurs que dans le Dockerfile), et `25-directories` batit ensuite
# `/run/lcars/console/<humain>` en 2710 `<humain>:<ce groupe>`. Une regression silencieuse s y
# solde par une landing qui meurt au boot sur « setpriv: unknown group ».

_bin_groupes() { # _bin_groupes — doublures de getent/groupadd/id/usermod, pilotees par des marqueurs
  local b="$BATS_TEST_TMPDIR/bin-groupes"; mkdir -p "$b"
  cat > "$b/getent" <<'STUB'
#!/usr/bin/env bash
# `getent group <nom>` : present seulement si le marqueur existe
[[ -e "$BATS_TEST_TMPDIR/groupe-$2" ]] || exit 2
printf '%s:x:4242:\n' "$2"
STUB
  cat > "$b/groupadd" <<'STUB'
#!/usr/bin/env bash
echo "GROUPADD:$*" >> "$BATS_TEST_TMPDIR/trace"
: > "$BATS_TEST_TMPDIR/groupe-${*: -1}"
STUB
  cat > "$b/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -nG) cat "$BATS_TEST_TMPDIR/membres" 2>/dev/null || echo "rien" ;;
  *)   printf 'uid=4242\n' ;;
esac
STUB
  cat > "$b/usermod" <<'STUB'
#!/usr/bin/env bash
echo "USERMOD:$*" >> "$BATS_TEST_TMPDIR/trace"
# `-aG <grp> <user>` : le groupe devient effectif
echo "$2" >> "$BATS_TEST_TMPDIR/membres"
STUB
  chmod 0755 "$b"/*
  export BIN_GROUPES="$b"

}

@test "ensure_group : la branche qui CREE — groupadd joue, le compteur bouge, le journal note" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    export PROV_JOURNAL_ACC="$BATS_TEST_TMPDIR/journal"
    ensure_group groupe-decor 4242
    [ "$PROV_CHANGED" -eq 1 ]
    grep -q "GROUPADD:-g 4242 groupe-decor" "$BATS_TEST_TMPDIR/trace"
    grep -q "posed_group groupe-decor" "$PROV_JOURNAL_ACC"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_group : un groupe DEJA la ne se recree pas, et le gid divergent est un DRIFT" {
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    : > "$BATS_TEST_TMPDIR/groupe-groupe-decor"
    ensure_group groupe-decor 4242
    [ "$PROV_CHANGED" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/trace" ]
    ensure_group groupe-decor 9999
    [ "$PROV_DRIFT" -ge 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"une machine ne se renumerote pas"* ]]
}

@test "ensure_member : la branche qui ECRIT — usermod joue, et l adhesion est RE-SONDEE apres" {
  # La re-sonde n est pas decorative : `usermod` peut rendre 0 sans que l adhesion soit effective
  # (nsswitch, base distante). Sans elle, le rail annoncerait une appartenance qu il n a pas.
  _bin_groupes
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    ensure_member humain-decor groupe-decor
    [ "$PROV_CHANGED" -eq 1 ]
    grep -q "USERMOD:-aG groupe-decor humain-decor" "$BATS_TEST_TMPDIR/trace"
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "ensure_member : un usermod qui MENT est attrape par la re-sonde" {
  _bin_groupes
  # celui-ci rend 0 sans rien changer — exactement le cas que la re-sonde existe pour voir
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_GROUPES/usermod"; chmod 0755 "$BIN_GROUPES/usermod"
  module_sh '
    PATH="$BIN_GROUPES:$PATH"
    rc=0; ensure_member humain-decor groupe-decor || rc=$?
    [ "$rc" -eq 1 ]
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"toujours hors de"* ]]
}

# ─── write_atomic — regression guards on the primitive itself ────────────────────────────────────

@test "write_atomic: identical content is a no-op (no change counted, mtime preserved)" {
  module_sh '
    f="$BATS_TEST_TMPDIR/wa.conf"
    printf "same\n" > "$f"; chmod 0644 "$f"
    mt_before="$(stat -c %Y "$f")"
    write_atomic "$f" 0644 <<< "same"
    [ "$PROV_CHANGED" -eq 0 ]
    [ "$(stat -c %Y "$f")" = "$mt_before" ]
  '
  [ "$status" -eq 0 ]
}

# ─── L ECRITURE QUI RATE — ET AUCUN TEMOIN DU CORPUS N EN JOUAIT UNE ────────────────────────────
#
# ⚠ `cat > "$tmp"` ETAIT NU. Les trois gestes suivants du primitif (chmod, chown, mv) REUSSISSENT
# tous sur un tampon tronque : le fichier basculait, PROV_CHANGED s incrementait, `p_chg` imprimait
# POSE, et le verbe rendait 0. Mesure du 2026-09-01 : sous `ulimit -f 0`, un fichier de ZERO octet
# annonce POSE.
#
# Ce que ca coute la ou le rail ecrit : `seat.uid` vide fait refuser tout `fleet start` par le
# GUARD B ; `services.env` vide demarre les quatre daemons sans FORGE_BASE_URL ; `wsl.conf` vide
# laisse l interop Windows OUVERTE sur une machine dont le bilan annonce la frontiere armee.
#
# ⚠ REDIRECTION, JAMAIS UN PIPE — c est le piege B3 de l en-tete de ce fichier. `printf | write_atomic`
# mettrait le primitif a DROITE d un pipe, donc dans un sous-shell, donc PROV_FAILED mourrait avec
# lui et ce temoin mesurerait le mauvais shell.
@test "write_atomic: une ecriture qui RATE ne bascule rien, et ne s annonce pas POSEE" {
  # ⚠ UNE DOUBLURE DE `cat`, ET SURTOUT PAS `ulimit -f 0` — MESURE DU 2026-09-02, HUIT HEURES
  # PERDUES. La premiere version posait `ulimit -f 0` dans le shell de `module_sh`. Jouee SEULE, la
  # suite passait ; jouee dans la SUITE COMPLETE, `bats-exec-suite` ecrit ses fichiers
  # intermediaires depuis ce meme shell, la limite les bloque, et le processus PEND au lieu
  # d echouer. Le gate de `pack.sh` et un `apply` de banc sont restes suspendus toute la nuit sur ce
  # seul test — un temoin qui prend en otage le harnais qui le joue.
  #
  # La doublure fait exactement le meme fait — `cat` rend non-zero sans avoir tout ecrit — de facon
  # DETERMINISTE et sans toucher a l environnement de bats. Un decor qui casse le harnais ne mesure
  # plus le code : il mesure le harnais.
  local b="$BATS_TEST_TMPDIR/bin-cat"; mkdir -p "$b"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$b/cat"; chmod 0755 "$b/cat"
  export BIN_CAT="$b"
  module_sh '
    PATH="$BIN_CAT:$PATH"
    src="$BATS_TEST_TMPDIR/source"; printf "contenu\n" > "$src"
    f="$BATS_TEST_TMPDIR/plein.conf"
    write_atomic "$f" 0644 < "$src" || true
    [ ! -e "$f" ]                 # rien na bascule
    [ "$PROV_CHANGED" -eq 0 ]     # rien nest compte comme pose
    [ "$PROV_FAILED" -ge 1 ]      # et lechec est COMPTE, pas avale
  ' 2>/dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ecriture du tampon RATEE"* ]]
  # ⚠ `<<<`, ET SON ABSENCE A COUTE LA NUIT. `refute_out` LIT STDIN — son en-tete l'ecrit
  # (`cmd | refute_out 'motif'`). Sans rien lui donner, son `grep` attend l'entree standard et le
  # test PEND. Joue seul, stdin est ferme et grep rend tout de suite ; joue par `shell_gate`, stdin
  # est un tube ouvert que personne n'alimente — et le harnais dort. Deux chantiers ont ete
  # suspendus huit heures dessus, et le premier diagnostic (`ulimit`) accusait le mauvais coupable.
  refute_out "POSE" <<<"$output"
}

@test "write_atomic: missing parent dir fails loud (PROV_FAILED counted)" {
  module_sh '
    write_atomic "$BATS_TEST_TMPDIR/absent-dir/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"dossier absent"* ]]
}

# ─── 6-131 — LA GARDE SYMLINK DES MUTATIONS PRIVILEGIEES ─────────────────────────────────────────
#
# L'attaque que ces tests epinglent : `ensure_dir` tenait un symlink-vers-dossier pour un dossier
# (`[[ -d ]]` suit les liens), puis `ensure_mode` chownait sa CIBLE. Le module WSL applique ces
# helpers EN ROOT a `$HOME/.config` de l'humain — donc `~/.config -> /etc`, et `sudo provision
# apply` donne `/etc` a cet humain.
#
# Ils tournent sans privileges : ce qui est mesure est le REFUS, pas l'effet root. Un test qui
# aurait besoin de root pour prouver une garde ne serait joue nulle part.

@test "6-131: ensure_dir REFUSE un symlink-vers-dossier au lieu de converger sa cible" {
  module_sh '
    victime="$BATS_TEST_TMPDIR/victime"; mkdir -p "$victime"; chmod 0755 "$victime"
    ln -s "$victime" "$BATS_TEST_TMPDIR/piege"
    ensure_dir "$BATS_TEST_TMPDIR/piege" 0700 || true
    [ "$PROV_FAILED" -ge 1 ]
    # LA cible n_a PAS bouge : c est tout l enjeu, pas le code de retour.
    [ "$(stat -c %a "$victime")" = "755" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "6-131: un symlink AU MILIEU du chemin est refuse aussi — c est celui de l attaque" {
  module_sh '
    victime="$BATS_TEST_TMPDIR/etc"; mkdir -p "$victime/systemd"; chmod 0755 "$victime/systemd"
    ln -s "$victime" "$BATS_TEST_TMPDIR/config"
    ensure_dir "$BATS_TEST_TMPDIR/config/systemd" 0700 || true
    [ "$PROV_FAILED" -ge 1 ]
    [ "$(stat -c %a "$victime/systemd")" = "755" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "ensure_mode: la forme « user: » est IDEMPOTENTE — sinon le rejeu rechowne a l'infini" {
  # LE DEUX-POINTS NU dit a `chown` « le groupe de CONNEXION de cet utilisateur » — il ne dit pas
  # LEQUEL. `stat` rend ensuite `bob:bob` la ou la cible s'ecrit `bob:`, donc une comparaison
  # litterale echoue A JAMAIS : le module re-chowne a chaque passe et compte une mutation.
  #
  # Mesure du 2026-08-21, DEUXIEME passe d'une install deja convergee :
  #   POSÉ  45-sudoers-toolchain: perms 0644 lordzurp: …/SKILL.md
  #   POSÉ  45-sudoers-toolchain: perms 0755 lordzurp: …/list.sh
  # Deux fichiers strictement identiques a ceux de la veille. Le mode de nuisance est doux et
  # durable : rien ne casse, mais « rejouer ne fait rien » devient faux — et c'est la propriete sur
  # laquelle tout ce rail est bati.
  # ⚠ C'EST LA DEUXIEME PASSE QU'ON MESURE, PAS LA PREMIERE. La premiere chowne pour de vrai — un
  # fichier neuf n'a pas encore le bon proprietaire — et compte donc une mutation legitime. Ce qui
  # doit etre nul, c'est le DELTA de la seconde. Une assertion sur le compteur absolu confondrait
  # « converge » et « n'a jamais rien fait ».
  module_sh '
    f="$BATS_TEST_TMPDIR/idem"; : > "$f"
    ensure_mode "$f" 0644 "$(id -un):" >/dev/null 2>&1
    avant="$PROV_CHANGED"
    out="$(ensure_mode "$f" 0644 "$(id -un):" 2>&1)"
    [ "$PROV_CHANGED" -eq "$avant" ] && [ -z "$out" ]
  '
  [ "$status" -eq 0 ]
}

@test "ensure_mode: TEMOIN — un groupe NOMME se compare toujours en entier" {
  # Sans ce pendant, un correctif qui ignorerait le groupe en toutes circonstances passerait le
  # temoin ci-dessus, et `root:fleet` cesserait d'etre converge — c'est-a-dire que /opt/lcars/var/tokens
  # pourrait deriver de groupe sans que rien ne le dise.
  module_sh '
    f="$BATS_TEST_TMPDIR/nomme"; : > "$f"
    ensure_mode "$f" 0644 "$(id -un):$(id -gn)" >/dev/null 2>&1
    avant="$PROV_CHANGED"
    out="$(ensure_mode "$f" 0644 "$(id -un):$(id -gn)" 2>&1)"
    [ "$PROV_CHANGED" -eq "$avant" ] && [ -z "$out" ]
    # Et le groupe est bien celui qui a ete NOMME, pas un autre laisse au systeme.
    [ "$(stat -c "%U:%G" "$f")" = "$(id -un):$(id -gn)" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-131: ensure_mode dit LIEN et non « absent » sur un lien casse" {
  # `[[ -e ]]` est faux sur un lien casse : diagnostique « absent », le piege reste invisible.
  module_sh '
    ln -s "$BATS_TEST_TMPDIR/nulle-part" "$BATS_TEST_TMPDIR/casse"
    ensure_mode "$BATS_TEST_TMPDIR/casse" 0600 || true
    [ "$PROV_FAILED" -ge 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
  [[ "$output" != *"ensure_mode: absent"* ]]
}

@test "6-131: write_atomic refuse d ecrire a travers un parent symlink" {
  module_sh '
    reel="$BATS_TEST_TMPDIR/reel"; mkdir -p "$reel"
    ln -s "$reel" "$BATS_TEST_TMPDIR/lien"
    write_atomic "$BATS_TEST_TMPDIR/lien/f" 0644 <<< "x" || true
    [ "$PROV_FAILED" -ge 1 ]
    [ ! -e "$reel/f" ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"composant symlink"* ]]
}

@test "6-131: TEMOIN — un chemin sans lien converge normalement (la garde ne mure rien)" {
  # Sans ce temoin, une garde qui refuserait TOUT passerait les quatre tests ci-dessus.
  module_sh '
    ensure_dir "$BATS_TEST_TMPDIR/vrai/imbrique" 0700
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(stat -c %a "$BATS_TEST_TMPDIR/vrai/imbrique")" = "700" ]
    write_atomic "$BATS_TEST_TMPDIR/vrai/imbrique/f" 0600 <<< "contenu"
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/vrai/imbrique/f")" = "contenu" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-131: ensure_symlink garde son droit de POSER un lien (la garde vise le parent)" {
  module_sh '
    ensure_symlink "$BATS_TEST_TMPDIR/lien-legitime" /dev/null
    [ "$PROV_FAILED" -eq 0 ]
    [ "$(readlink "$BATS_TEST_TMPDIR/lien-legitime")" = "/dev/null" ]
  '
  [ "$status" -eq 0 ]
}

# ─── 6-130 — LE VERROU PRIVILEGIE N EST PLUS DANS UN DOSSIER PARTAGE ─────────────────────────────

@test "6-130: prov_lock_path ignore TMPDIR — un verrou dont l appelant choisit l emplacement n en est pas un" {
  module_sh '
    export TMPDIR="$BATS_TEST_TMPDIR/pirate"; mkdir -p "$TMPDIR"
    lock="$(prov_lock_path)" || true
    [[ "$lock" != "$TMPDIR"* ]]
  '
  [ "$status" -eq 0 ]
}

# ─── LE VERROU EST PER-HUMAIN QUAND LA PASSE L EST ──────────────────────────────────────────────
#
# ⚠ CE QUE CES TEMOINS GARDENT A COUTE L EQUIPEMENT D UN COMPTE. Mesure du 2026-08-25 : le
# convergeur cree l humain de fleet PENDANT que l install tient son propre apply, appelle
# `provision apply --human lcars --only 40-claude-bin …` pour l equiper, et se fait refuser — « un
# autre apply est en cours ». L humain se retrouve avec un home, un shell, un groupe, et PAS de
# `claude` : il ne peut lancer aucune fleet, et rien ne le lui dit.
#
# La collision est STRUCTURELLE : `48-forge-host` cree le compte de forge PENDANT l apply et le
# convergeur poll toutes les 30 s. C est le chemin nominal d une premiere install, pas un cas de bord.
#
# ⚖ « on traite chaque user, on fait pas un global : si l user qu on teste est ok et qu un autre user
# est fail, on passe par dessus » — l unite de travail est l humain, le verrou la suit.

@test "verrou: deux humains ont deux verrous DISTINCTS — les serialiser ne protegeait rien" {
  module_sh '
    a="$(prov_lock_path alice)"
    b="$(prov_lock_path bob)"
    [[ "$a" != "$b" ]]
  '
  [ "$status" -eq 0 ]
}

@test "verrou: le per-humain et le GLOBAL coexistent — c est le defaut qui a casse l install" {
  # LE TEMOIN CENTRAL. Un apply complet tient le verrou global ; l equipement d un humain doit
  # pouvoir tourner EN MEME TEMPS. Deux `flock` REELS sur les deux chemins, pas une comparaison de
  # chaines : ce qui compte n est pas que les noms different, c est qu ils ne se bloquent pas.
  module_sh '
    g="$(prov_lock_path)"
    h="$(prov_lock_path lcars)"
    exec 8>"$g"; flock -n 8 || exit 1
    exec 7>"$h"; flock -n 7 || exit 2
    exec 7>&-; exec 8>&-
  '
  [ "$status" -eq 0 ]
}

@test "verrou: le MEME humain deux fois se bloque quand meme — la portee n a pas supprime le verrou" {
  # LE TEMOIN DU TEMOIN. Sans lui, un `prov_lock_path` qui rendrait un chemin unique par APPEL
  # passerait celui du dessus et ne verrouillerait plus rien du tout.
  #
  # ⚠ DEUX APPELS, PAS UNE VARIABLE REUTILISEE — ET MA PREMIERE ECRITURE FAISAIT L INVERSE. Elle
  # appelait `prov_lock_path` UNE fois et ouvrait les deux descripteurs sur la meme chaine : un
  # chemin unique par appel etait alors indetectable, et la mutation qui l introduisait passait
  # VERTE. Ce qui se verifie ici n est pas que `flock` fonctionne — c est que le MEME humain resout
  # au MEME verrou, deux appels de suite.
  module_sh '
    exec 8>"$(prov_lock_path lcars)"; flock -n 8 || exit 1
    exec 7>"$(prov_lock_path lcars)"
    flock -n 7 && exit 2
    exec 7>&-; exec 8>&-
  '
  [ "$status" -eq 0 ]
}

@test "verrou: une portee qui s evade du dossier prouve est REFUSEE" {
  # Le nom de portee devient un nom de FICHIER. Un `../` deplacerait le verrou hors du dossier dont
  # on vient de prouver le mode et le proprietaire — et le prouver pour ecrire ailleurs serait pire
  # que ne pas le prouver du tout.
  module_sh 'prov_lock_path "../evade" >/dev/null 2>&1 && exit 1; :'
  [ "$status" -eq 0 ]
  module_sh 'prov_lock_path "a/b" >/dev/null 2>&1 && exit 1; :'
  [ "$status" -eq 0 ]
}

@test "6-130: le verrou vit dans un dossier 0700 possede par l appelant" {
  module_sh '
    lock="$(prov_lock_path)"
    dir="$(dirname "$lock")"
    [ "$(stat -c %a "$dir")" = "700" ]
    [ "$(stat -c %u "$dir")" = "$(id -u)" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-130: sans dossier runtime, c'est un REFUS qui NOMME le parent — jamais un repli" {
  # LE CAS N'EST PAS THEORIQUE, C'EST L'ETAT NOMINAL D'UN COMPTE DE SERVICE. Mesure du 2026-08-20
  # sur le poste natif : `lcars` (uid 1001) n'a `/run/user/1001` par AUCUNE voie — ni `sudo -u`, ni
  # `runuser`, ni un login ssh, parce qu'aucune de ces voies n'ouvre de session logind pour lui.
  #
  # Ce que ce temoin garde n'est donc pas une bizarrerie : c'est que dans cet etat la lib REFUSE et
  # DIT ou, au lieu de se rabattre sur un emplacement partage. Un repli silencieux vers /tmp
  # rouvrirait exactement le trou que 6-130 a ferme, et il le rouvrirait la ou personne ne regarde —
  # sur les machines sans session, c'est-a-dire tous les comptes de service.
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/absent/xdg"
  module_sh 'prov_lock_path'
  [ "$status" -ne 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/absent"* ]]
  [[ "$output" == *"pas d'emplacement sur"* ]]
}

# ─── 6-109 — L AUTORITE DU SELF-UPDATE ROOT ETAIT UNE SOUS-CHAINE ────────────────────────────────
#
# `case "$REMOTE_URL" in *"$PROV_EXPECTED_REPO"*)`. Avec `fleet/lcars` attendu, l URL
# `https://hote-attaquant/attaquant/fleet/lcars-malware.git` la CONTIENT — donc pull, puis
# `exec "$SELF" apply` sur ce code, EN ROOT. Ni l hote, ni le proprietaire, ni la fin du nom.
#
# Aucun test ne couvrait `update` avant ceci.

@test "6-109: l URL de l attaque de la fiche ne rend PAS l autorite attendue" {
  module_sh '
    got="$(prov_parse_remote "https://hote-attaquant/attaquant/fleet/lcars-malware.git")" || got=REFUS
    [ "$got" != "forge.example.org/fleet/lcars" ]
    # Et ce quon lit dit POURQUOI : trois segments de chemin, ce nest pas <owner>/<repo>.
    [ "$got" = "REFUS" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: un suffixe sur le nom du depot ne passe plus" {
  module_sh '
    got="$(prov_parse_remote "https://forge.example.org/fleet/lcars-malware.git")"
    [ "$got" = "forge.example.org/fleet/lcars-malware" ]
    [ "$got" != "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: le MEME depot sur un AUTRE hote est un autre triplet" {
  module_sh '
    a="$(prov_parse_remote "https://forge.example.org/fleet/lcars.git")"
    b="$(prov_parse_remote "https://hote-attaquant/fleet/lcars.git")"
    [ "$a" = "forge.example.org/fleet/lcars" ]
    [ "$b" = "hote-attaquant/fleet/lcars" ]
    [ "$a" != "$b" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: les trois formes admises rendent le MEME triplet" {
  module_sh '
    h="$(prov_parse_remote "https://forge.example.org/fleet/lcars.git")"
    s="$(prov_parse_remote "ssh://git@forge.example.org:2222/fleet/lcars.git")"
    p="$(prov_parse_remote "git@forge.example.org:fleet/lcars.git")"
    [ "$h" = "forge.example.org/fleet/lcars" ]
    [ "$s" = "forge.example.org/fleet/lcars" ]
    [ "$p" = "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: un remote qui porte un CREDENTIAL est refuse (l utilisateur nu, lui, passe)" {
  # `user:token@` ferait de l autorite de mise a jour un porteur de secret. `git@`, en revanche,
  # est la syntaxe normale de SSH : la refuser serait un mur, pas une garde.
  module_sh '
    prov_parse_remote "https://user:token@forge.example.org/fleet/lcars.git" && exit 1
    prov_parse_remote "ssh://git@forge.example.org/fleet/lcars.git" >/dev/null || exit 1
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "6-109: une URL qui MIME l autorite dans son userinfo rend l hote REEL" {
  # `https://fleet/lcars@hote-attaquant/x/y.git` : la partie qui ressemble a l autorite attendue
  # est AVANT le `@`, donc elle ne dit rien de qui sera contacte. Le parse rend l hote reel, et
  # c est la comparaison exacte qui refuse — pas un filtre sur la forme.
  module_sh '
    got="$(prov_parse_remote "https://fleet/lcars@hote-attaquant/x/y.git")"
    [ "$got" = "hote-attaquant/x/y" ]
    [ "$got" != "forge.example.org/fleet/lcars" ]
  '
  [ "$status" -eq 0 ]
}

@test "6-109: une forme inconnue est REFUSEE, jamais devinee" {
  module_sh '
    prov_parse_remote "/chemin/local/fleet/lcars" && exit 1
    prov_parse_remote "fleet/lcars" && exit 1
    prov_parse_remote "https://forge.example.org/juste-un-segment" && exit 1
    exit 0
  '
  [ "$status" -eq 0 ]
}

@test "6-109: TEMOIN — l hote est insensible a la casse, le chemin NON" {
  module_sh '
    [ "$(prov_parse_remote "https://Forge.Example.ORG/fleet/lcars.git")" = "forge.example.org/fleet/lcars" ]
    [ "$(prov_parse_remote "https://forge.example.org/Fleet/LCARS.git")" = "forge.example.org/Fleet/LCARS" ]
  '
  [ "$status" -eq 0 ]
}

# ─── advertise_addr — « quelle est mon IP » N'EST PAS « par ou on m'atteint » ────────────────────
#
# Mesure du 2026-08-18, ce poste, WSL2 en mode NAT : le banc annoncait 172.25.115.129:20999 (l'eth0
# de la VM, derriere un commutateur Hyper-V NATe — routee depuis AUCUNE autre machine, et
# reattribuee a chaque redemarrage de WSL) pendant que le navigateur de l'hote arrivait en
# localhost:20999. La porte du deck refusait, correctement, une entree non declaree : l'adresse
# annoncee etait fausse depuis le debut, et c'est le premier acces par navigateur qui l'a dit.
# Le discriminant est le MODE RESEAU, pas « est-ce WSL » : en mode miroir, `ip route get` redevient vrai.

@test "advertise_addr: un bind PRECIS est l'adresse — rien a deriver" {
  module_sh '
    advertise_addr 127.0.0.5
    [ "$PROV_ADVERTISE" = "127.0.0.5" ]
    [ -z "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: WSL en NAT annonce localhost, et DIT pourquoi" {
  # ⚠ `PROV_SUBSTRATE`, PAS UN STUB DE `detect_substrate`. La fonction lit d'abord ce que le RUNNER a
  # tranche (`provision --substrate`) et ne sonde qu'a defaut ; un stub de la sonde ne decrirait donc
  # plus le chemin que la production prend. C'est aussi l'idiome deja etabli ailleurs dans ce corpus
  # (`directories_runtime.bats`, `deploy_manifest.bats`) : le substrat SE POSE, il ne se simule pas.
  module_sh '
    PROV_SUBSTRATE=wsl
    wsl_networking_mode() { echo nat; }
    lan_addr() { echo 172.25.115.129; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "localhost" ]
    [ -n "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: WSL en MIROIR n'est pas un cas a part — l'adresse de sortie est vraie" {
  module_sh '
    PROV_SUBSTRATE=wsl
    wsl_networking_mode() { echo mirrored; }
    lan_addr() { echo 10.42.0.63; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "10.42.0.63" ]
    [ -z "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: aucune adresse de sortie = loopback ANNONCEE COMME TELLE" {
  module_sh '
    PROV_SUBSTRATE=linux
    lan_addr() { echo ""; }
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "127.0.0.1" ]
    [ -n "$PROV_ADVERTISE_WHY" ]
  '
  [ "$status" -eq 0 ]
}

@test "advertise_addr: n'imprime RIEN — la capture \$( ) perdrait le second fait" {
  # LE PIEGE DE LANGAGE, TENU PAR UN TEMOIN. `a=\"\$(advertise_addr ...)\"` ouvre un SOUS-SHELL :
  # toute globale posee dedans meurt avec lui. Une fonction qui imprimerait l'adresse et poserait
  # la raison perdrait donc la raison, en silence, chez tous ses appelants. Elle pose les DEUX.
  module_sh '
    PROV_SUBSTRATE=linux
    lan_addr() { echo 10.42.0.63; }
    out="$(advertise_addr 0.0.0.0)"
    [ -z "$out" ]
    # et la globale posee DANS le sous-shell n en est pas ressortie : le parent est intact.
    [ -z "$PROV_ADVERTISE" ]
    # la seule forme qui marche : appeler, PUIS lire.
    advertise_addr 0.0.0.0
    [ "$PROV_ADVERTISE" = "10.42.0.63" ]
  '
  [ "$status" -eq 0 ]
}

# ─── run_step — une etape longue qui dit ou elle en est ──────────────────────────────────────────
#
# `run_quiet` est muet par contrat, et c'est juste pour trente secondes. Le build de la release
# dure plusieurs minutes : rien ne distingue alors « ca travaille » de « c'est fige », et la seule
# chose qu'un humain fasse d'un ecran immobile, c'est l'interrompre. Ce qui est tenu ici : la phase
# vient de la sortie REELLE de l'enfant (aucun pourcentage devine), et le rc traverse.

# ⚠ CE QU'UN ECHANTILLONNEUR NE PROMET PAS, ON NE LE LUI DEMANDE PAS. `run_step` relit le fichier de
# sortie une fois par SECONDE et n'imprime que si la phase lue differe de la lecture precedente : une
# phase qui nait et meurt entre deux ticks n'est JAMAIS vue, et c'est le comportement voulu d'un
# indicateur de progression — rater une ligne ne coute rien, personne n'agit dessus.
#
# Ce test a longtemps assert « EXACTEMENT deux lignes » sur un enfant qui vivait 2,4 s : il exigeait
# donc que l'echantillonneur ATTRAPE un transitoire, ce qui est une propriete de l'ORDONNANCEMENT et
# pas du code. Il tenait a une fenetre de 0,4 s et rougissait des que la machine etait chargee (vu le
# 2026-08-20 : vert lance seul, rouge dans une passe des 32 suites). Le reflexe — allonger les
# `sleep` — achete de la chance d'ordonnancement pour satisfaire une assertion qui ne devrait pas
# avoir cette forme, et ne rend jamais le temoin sain : juste plus lent a mentir.
#
# La course est donc retiree, pas rembourree. Ce que le contrat dit vraiment se tient sans elle, et
# se decoupe en deux :
#   - la RECONNAISSANCE de phase est une fonction PURE d'un fichier — testee sur `_prov_phase_of`
#     ci-dessous, sans aucun enfant ni aucune horloge. Elle n'avait AUCUN temoin a elle : le test
#     temporel etait sa seule couverture, et c'est ce qui lui avait donne cette forme ;
#   - la NON-VERBOSITE (« pas une ligne par seconde ») s'enonce sur des invariants vrais quel que
#     soit le planning : moins de lignes que de ticks ecoules, et jamais deux lignes consecutives
#     portant la meme phase.

@test "run_step: la reconnaissance de phase est une fonction pure — aucune horloge, aucune course" {
  local f="$BATS_TEST_TMPDIR/out"
  # Chaque libelle que la sonde sait nommer, mis en regard de ce qu'elle en dit. La DERNIERE ligne
  # reconnue gagne : c'est ce qui fait avancer l'affichage quand un build enchaine ses etapes.
  module_sh '
    f="'"$f"'"
    printf "Compiling 3 files\n"                         > "$f"; _prov_phase_of "$f"
    printf "Compiling 3 files\nRunning ExUnit\n"         > "$f"; _prov_phase_of "$f"
    printf "Running ExUnit\nFinished in 12.0s\n"         > "$f"; _prov_phase_of "$f"
    printf "=== shell_gate\n"                            > "$f"; _prov_phase_of "$f"
    printf "Release created at _build\n"                 > "$f"; _prov_phase_of "$f"
    printf "rien de reconnaissable\n"                    > "$f"; _prov_phase_of "$f"
    : > "$f"                                                   ; _prov_phase_of "$f"
    _prov_phase_of "/nonexistent/pas-de-fichier"
  '
  [ "$status" -eq 0 ]
  local -a lines; mapfile -t lines <<< "$output"
  [ "${lines[0]}" = "compilation" ]
  [ "${lines[1]}" = "suite ExUnit (3000+ temoins)" ]
  [ "${lines[2]}" = "suite ExUnit terminee" ]
  [ "${lines[3]}" = "gate shell (python + bats)" ]
  [ "${lines[4]}" = "release posee" ]
  # ⚠ LES TROIS DERNIERS SONT LE FOND DU CONTRAT, ET CE TEMOIN APPELLE LA FONCTION EN DIRECT EXPRES.
  # « aucune ligne reconnue » est le cas NORMAL (la premiere seconde de toute etape) : grep rend 1,
  # et sous `pipefail` c'est le code de l'assignation. Mesure du 2026-08-20 : appelee directement la
  # fonction TUAIT un shell `set -euo pipefail`, alors qu'en substitution — la seule forme qu'utilise
  # `run_step` — elle survivait. Elle ne tenait donc pas par son code mais par son unique site
  # d'appel, et le premier appelant a l'ecrire autrement mourait au premier tick. Le `|| true` du
  # site le corrige ; ce temoin est ce qui l'empeche de repartir.
  #
  # Rien de reconnu, fichier vide, fichier ABSENT rendent tous « demarrage » — jamais une chaine
  # vide, qui ferait imprimer une ligne tronquee a chaque tick.
  [ "${lines[5]}" = "demarrage" ]
  [ "${lines[6]}" = "demarrage" ]
  [ "${lines[7]}" = "demarrage" ]
}

@test "run_step: une ligne par CHANGEMENT de phase — pas une par seconde" {
  # L'enfant vit plusieurs ticks en restant dans la MEME phase : c'est le seul cas ou « une par
  # seconde » se distingue de « une par changement », et il ne depend d'aucun timing fin.
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; sleep 4"
  '
  [ "$status" -eq 0 ]
  local n; n="$(printf '%s\n' "$output" | grep -c '>>')"
  # Au moins une ligne (la phase a ete vue), et STRICTEMENT moins que les ticks ecoules : une boucle
  # qui imprimerait a chaque sonde en aurait rendu 4 ou 5.
  [ "$n" -ge 1 ]
  [ "$n" -lt 4 ]
  # Et aucune repetition : deux lignes consecutives portant la meme phase, c'est « par seconde ».
  [ "$(printf '%s\n' "$output" | grep '>>' | sort -u | wc -l)" -eq "$n" ]
  [[ "$output" == *"build · compilation"* ]]
}

@test "run_step: le rc de l'enfant TRAVERSE la boucle de sonde" {
  # La cicatrice B3 : sonder un fichier plutot que brancher un pipe existe POUR ca — `cmd | while
  # read` mettrait la boucle dans un sous-shell et perdrait le rc. Sans ce temoin, remplacer la
  # sonde par un pipe passerait tous les autres.
  module_sh '
    run_step "build" -- bash -c "echo Compiling 3 files; exit 3" || echo "RC=$?"
  '
  [[ "$output" == *"RC=3"* ]]
}

@test "run_step: l'echec garde le rc, COMPTE, borne l'ecran et CONSERVE le fichier" {
  module_sh '
    export PROV_DUMP_LINES=3
    rc=0
    run_step "etape" -- bash -c "for i in \$(seq 1 200); do echo ligne-\$i; done; sleep 1.1; exit 7" || rc=$?
    [ "$rc" -eq 7 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ligne-200"* ]]
  [[ "$output" != *"ligne-100"* ]]
  [[ "$output" == *"sortie COMPLÈTE conservée"* ]]
  # le fichier nomme existe VRAIMENT — l'ancienne forme le supprimait juste apres l'avoir cite
  f="$(printf '%s\n' "$output" | sed -n 's/.*conservée : \([^ ]*\).*/\1/p' | tail -n1)"
  [ -s "$f" ]
  [ "$(wc -l < "$f")" -eq 200 ]
  rm -f "$f"
}

# ⚠ CE TEMOIN COMPTAIT UN REPERTOIRE PARTAGE, ET IL MESURAIT DONC LA MACHINE QUI LE JOUE. Il faisait
# son `find` dans `${TMPDIR:-/tmp}` — le /tmp de tout le monde. Mesure du 2026-09-02 : 551 fichiers
# `prov-out.*` y dormaient deja, et DEUX gates tournaient en parallele sur la machine, chacune en
# creant et en supprimant. Le compte bougeait entre le « avant » et le « apres » pour des raisons
# qui n'ont rien a voir avec `run_step`.
#
# Il a rougi dans la gate du 2026-09-02 et il est passe VERT rejoue seul, a la meme seconde et sur
# le meme code : la difference etait le voisinage, pas le sujet. C'est exactement ce que l'en-tete
# de `system_manifest.bats` interdit — « un temoin qui pretendrait mesurer la machine depuis ce
# poste mesurerait ce poste ».
#
# Le decor POSSEDE desormais son TMPDIR, comme le reste du corpus. Le fait garde est le meme, et il
# devient vrai quoi qu'il arrive a cote.
@test "run_step: un succes ne laisse AUCUN fichier derriere lui" {
  local container="$BATS_TEST_TMPDIR/tmp-run-step"; mkdir -p "$container"
  before="$(find "$container" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  TMPDIR="$container" module_sh 'run_step "ok" -- bash -c "echo rien; sleep 1.1"'
  [ "$status" -eq 0 ]
  after="$(find "$container" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  [ "$after" -eq "$before" ] \
    || { echo "run_step a laisse $((after - before)) fichier(s) dans son propre TMPDIR :"; find "$container" -maxdepth 1 -name 'prov-out.*'; return 1; }
}

@test "run_step --ok N : un code tolere n'est pas un echec, et il NE TUE PAS l'appelant" {
  # ⚠ LE DEFAUT QUE CE TEMOIN GARDE ETAIT ECRIT, COMMENTE, ET INATTEIGNABLE. `deploy/lib/deploy-release.sh` rend 3
  # quand la release est posee mais le cablage PATH incomplet — le cas NOMINAL des qu'il tourne en
  # tant qu'humain. 60-deploy portait la tolerance juste sous l'appel... et sous `set -euo pipefail`
  # une commande nue qui rend 3 tue le module AVANT la ligne qui lit `$?`. Le commentaire decrivait
  # une intention que le code ne pouvait pas executer, et ce chemin ne se prend QUE hors conteneur —
  # donc nulle part ou on regardait. Mesure du 2026-08-18, rail natif sur Ubuntu neuve.
  module_sh '
    run_step --ok 3 "etape" -- bash -c "sleep 1.1; exit 3"
    # on est encore la : `set -e` ne nous a pas tues
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --ok N : un code NON tolere reste un echec entier" {
  module_sh '
    rc=0
    run_step --ok 3 "etape" -- bash -c "echo boum; sleep 1.1; exit 4" || rc=$?
    [ "$rc" -eq 4 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "run_step --ok N : la tolerance survit a --verbose — un mode d'affichage ne change pas un verdict" {
  # ⚠ LE DEFAUT PRECEDENT AVAIT UNE SECONDE MOITIE, ET ELLE A SURVECU AU CORRECTIF. La branche
  # `PROV_VERBOSE=1` de `run_step` deleguait a `run_quiet`, qui ne connait AUCUNE tolerance et
  # `p_fail`-e sur tout rc non nul : le meme rc 3 de `deploy/lib/deploy-release.sh` redevenait un echec des que
  # quelqu'un lancait `provision --verbose` — c'est-a-dire exactement quand ca va mal et qu'on
  # regarde. Et `PROV_LAST_RC` n'etait pas pose du tout : l'appelant qui le relit lisait le code d'un
  # appel PRECEDENT, donc prenait une decision sur la mesure d'autre chose.
  #
  # Les deux temoins ci-dessus tournaient en mode nominal et restaient VERTS pendant ce temps.
  module_sh '
    export PROV_VERBOSE=1
    run_step --ok 3 "etape" -- bash -c "exit 3"
    [ "$PROV_LAST_RC" -eq 3 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --verbose : PLUSIEURS --ok sont tous tolérés, pas seulement le premier" {
  # ⚠ MES DEUX TEMOINS VERBOSE NE COUVRAIENT QU'UN SEUL `--ok`, ET LA LACUNE A ETE PROUVEE PAR
  # MUTATION : en remplacant la boucle `for c in "${ok_codes[@]}"` par un test sur `ok_codes[0]`
  # seul, les deux restaient VERTS — alors que `64-services` appelle `run_step --ok 1 --ok 2`, donc
  # le rc 2 du convergeur (drift residuel, le cas NOMINAL d'un humain frais) redevenait un echec
  # d'apply des qu'on lance `provision --verbose`.
  #
  # Un contrat qui accepte une LISTE se mesure sur au moins deux elements, et sur le DERNIER : c'est
  # celui qu'une implementation qui ne lit que le premier laisse tomber.
  module_sh '
    export PROV_VERBOSE=1
    run_step --ok 1 --ok 2 "etape" -- bash -c "exit 2"
    [ "$PROV_LAST_RC" -eq 2 ]
    [ "$PROV_FAILED" -eq 0 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"code attendu"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "run_step --verbose : un code NON tolere reste un echec entier, et PROV_LAST_RC le dit" {
  # Le pendant : sans lui, une branche verbose qui tolererait TOUT passerait le temoin precedent.
  module_sh '
    export PROV_VERBOSE=1
    rc=0
    run_step --ok 3 "etape" -- bash -c "exit 4" || rc=$?
    [ "$rc" -eq 4 ]
    [ "$PROV_LAST_RC" -eq 4 ]
    [ "$PROV_FAILED" -eq 1 ]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL"* ]]
}

# ─── LA TOOLCHAIN N'EST PLUS UN MIROIR : ELLE EST UN SEUL OBJET, ET C'EST LUI QU'ON GARDE ───────
#
# ⚠ CE QUI VIVAIT ICI, ET POURQUOI CE N'EST PLUS CE QU'IL FAUT SURVEILLER. Deux rails posaient la
# meme toolchain par deux mecanismes, avec deux versions ecrites a deux endroits :
#
#   rail poste   `provision-lib.sh` : PROV_ELIXIR_VERSION + PROV_ELIXIR_OTP_MAJOR, zip verifie sha256
#   rail conteneur   `Dockerfile`       : ARG BUILD_IMAGE=hexpm/elixir:<ver>-erlang-<otp>...@sha256:...
#
# Ce temoin comparait les deux chiffres. Il etait juste, et il a tenu — mais surveiller l'accord de
# deux autorites est le second choix : les DEUX rails demandent maintenant `erlang` et `elixir` a
# l'apt de la MEME image de base (ubuntu 26.04, la cible du rail poste). Il n'y a plus deux versions
# a accorder ; il y a une base, et deux planchers qui la jugent.
#
# CE QUI EST GARDE ICI EST DONC LE FAIT QUI A REMPLACE LE MIROIR, EN TROIS MURS :
#   1. la lib ne porte plus de pin EXACT — un cliquet, parce qu'un pin qui revient rouvre la
#      divergence sans qu'aucune ligne ne dise qu'elle est rouverte ;
#   2. les deux etages du Dockerfile portent la MEME image de base, digest compris — c'est ce qui
#      fait que l'ERTS bundle au build est chez lui au runtime, et que la toolchain de compilation
#      EST celle de la machine cible ;
#   3. les deux rails demandent la paire a apt, chacun dans son fichier.
#
# ⚠ CE QUI N'EST PAS VERIFIABLE ICI, ET QUI NE DOIT PAS ETRE DEDUIT : l'OTP que cet apt SERT. Un
# mur statique lit des noms de paquets, pas le contenu d'un depot. Le plancher est tenu a
# l'execution par `15-toolchain` (`check` le sonde, `apply` echoue en le nommant), et c'est le seul
# endroit qui puisse le savoir.
@test "la lib ne porte plus de pin EXACT de toolchain — le cliquet du retour au zip" {
  # ⚠ GARDE D'INSTRUMENT INVERSEE. Un temoin d'ABSENCE est vert quand son sujet a disparu — donc
  # aussi quand le FICHIER a disparu, ou que le chemin est faux. On prouve d'abord qu'on lit bien
  # la lib, par un defaut qui doit y etre.
  [ -f "$LIB" ]
  grep -qE '^: "\$\{PROV_ELIXIR_OTP_MAJOR:=[0-9]+\}"' "$LIB" \
    || { echo "extraction ratee : PROV_ELIXIR_OTP_MAJOR introuvable dans $LIB — ce temoin ne lit pas ce qu'il croit"; return 1; }

  ! grep -qE '^: "\$\{PROV_ELIXIR_VERSION:=' "$LIB" \
    || { echo "PROV_ELIXIR_VERSION est revenu dans $LIB : un pin exact en face d'une distro qui sert sa propre version"; return 1; }
  ! grep -qE '^: "\$\{PROV_ELIXIR_ZIP_SHA256:=' "$LIB" \
    || { echo "PROV_ELIXIR_ZIP_SHA256 est revenu dans $LIB : le precompile telecharge est de retour"; return 1; }
  grep -qE '^: "\$\{PROV_ELIXIR_MIN:=[0-9]+\.[0-9]+\}"' "$LIB" \
    || { echo "PROV_ELIXIR_MIN absent de $LIB : plus rien ne dit quel Elixir la distro doit au moins servir"; return 1; }
}

@test "les deux etages de l'image partent de la MEME base, digest compris" {
  local dockerfile="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  [ -f "$dockerfile" ]

  local build runtime
  build="$(sed -n 's/^ARG BUILD_IMAGE=//p' "$dockerfile")"
  runtime="$(sed -n 's/^ARG RUNTIME_IMAGE=//p' "$dockerfile")"

  # ⚠ GARDE D'INSTRUMENT : deux extractions ratees rendent deux chaines VIDES, donc EGALES. Un mur
  # qui compare du vide a du vide est vert sur n'importe quelle derive.
  [ -n "$build" ]   || { echo "extraction ratee : ARG BUILD_IMAGE dans $dockerfile"; return 1; }
  [ -n "$runtime" ] || { echo "extraction ratee : ARG RUNTIME_IMAGE dans $dockerfile"; return 1; }

  [ "$build" = "$runtime" ] \
    || { echo "les deux etages divergent — build « $build », runtime « $runtime ». L'ERTS bundle au build n'est chez lui au runtime que si la base est la meme."; return 1; }

  # Et cette base EST la cible du rail poste, pas une distro tierce.
  [[ "$build" == ubuntu:* ]] \
    || { echo "base « $build » : le rail poste cible ubuntu, l'image doit batir dessus"; return 1; }
  [[ "$build" == *@sha256:* ]] \
    || { echo "base « $build » sans digest : l'immutabilite ne se declare pas, elle s'epingle"; return 1; }
}

@test "les deux rails demandent erlang ET elixir a apt — un mecanisme, deux fichiers" {
  local dockerfile="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  local mod="$BATS_TEST_DIRNAME/../../modules.d/15-toolchain.sh"
  [ -f "$dockerfile" ] && [ -f "$mod" ]

  grep -qE '^\s+erlang elixir \\?$' "$dockerfile" \
    || { echo "l'etage build du Dockerfile ne demande plus « erlang elixir » a apt"; return 1; }
  grep -qE 'apt_ensure erlang elixir' "$mod" \
    || { echo "15-toolchain ne demande plus « erlang elixir » a apt"; return 1; }
}

@test "lan_addr tient son contrat « vide si indeterminable » — meme sans \`ip\`" {
  # ⚠ TROISIEME INCARNATION DE B5 DANS LA MEME JOURNEE. `ip` n'existe pas partout — l'image du job
  # CI ne l'a pas — et sous `pipefail` une commande introuvable rend 127 que le pipeline propage :
  # la fonction rendait 127, l'assignation echouait, `set -e` tuait l'appelant. Mesure du
  # 2026-08-18 : huit temoins de `bench_up_verdict.bats` rouges DANS la CI et verts partout
  # ailleurs, parce que `bench-up.sh` mourait sur la ligne qui derive une adresse.
  module_sh '
    a="$(PATH=/nonexistent lan_addr)"
    [ -z "$a" ]
    # et advertise_addr, qui l en depend, survit aussi
    PATH=/nonexistent advertise_addr 0.0.0.0
    [ -n "$PROV_ADVERTISE" ]
  '
  [ "$status" -eq 0 ]
}

# ─── LE SIEGE — les quatre branches, et celle qui n'existait nulle part ──────────────────────────
#
# La regle : celui des deux qui existe nomme l'autre, et le lien est enregistre. La QUATRIEME
# branche — les deux existent et ne s'accordent PAS — n'etait ecrite dans aucun rail : c'est le
# controle qui aurait attrape la divergence avant qu'elle casse.

@test "siege: la table et le candidat unix s'accordent -> agree" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding amiral
    [ "$PROV_SEAT_BINDING" = agree ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
    # La SOURCE est un fait distinct du verdict : un operateur qui diagnostique une forge en carafe
    # lit cette ligne, et « forge » y serait un mensonge.
    [ "$PROV_SEAT_SOURCE" = table ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: la table et le candidat unix DIVERGENT -> diverge, et la table fait foi" {
  # Le nom enregistre correspond a ce qui est SUR LE DISQUE (le home du siege). Un candidat qui
  # dit autre chose est le defaut, pas la table.
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding quelquun-dautre
    [ "$PROV_SEAT_BINDING" = diverge ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: le cote durable nomme, unix n'a pas de candidat -> derived, source NOMMEE" {
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    prov_seat_binding
    [ "$PROV_SEAT_BINDING" = derived ]
    [ "$PROV_SEAT_SOURCE" = table ]
    [ "$PROV_SEAT_LOGIN" = amiral ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: unix nomme, le cote durable est muet -> seeded" {
  # Pas de table, pas de jeton, pas d URL : `prov_forge_seat_login` rend vide. Un appelant qui lit
  # du vide ne conclut pas « personne », seulement « pas su » — et le candidat unix reste.
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/absente"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding loperateur
    [ "$PROV_SEAT_BINDING" = seeded ]
    [ "$PROV_SEAT_SOURCE" = candidat ]
    [ "$PROV_SEAT_LOGIN" = loperateur ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: ni l un ni l autre -> unknown, et AUCUN nom n est pose" {
  # Un siege invente s installe et survit a la cause qui l a produit ; un refus se lit et se repare.
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/absente"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding
    [ "$PROV_SEAT_BINDING" = unknown ]
    [ -z "$PROV_SEAT_LOGIN" ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: l enregistrement ECRIT UNE FOIS et ne se re-ecrit jamais" {
  # Le home du siege vit sous son nom : changer ce nom plus tard laisserait un home orphelin.
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    prov_seat_record amiral 1000
    prov_seat_record quelquun-dautre 1000
    [ "$(prov_seat_from_map)" = amiral ]
    [ "$(grep -c . "$PROV_UID_MAP_FILE")" -eq 1 ]
  '
  [ "$status" -eq 0 ]
}

@test "siege: la table PASSE AVANT la forge — un redemarrage tient sans reseau" {
  # `prov_forge_seat_login` n est meme pas appele quand la ligne existe : on le prouve en rendant
  # son chemin impraticable (aucune URL, aucun jeton) et en exigeant quand meme une reponse.
  module_sh '
    export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/map"
    printf "1\t1000\tamiral\n" > "$PROV_UID_MAP_FILE"
    export PROV_MASTER_TOKEN_FILE="$BATS_TEST_TMPDIR/pas-de-jeton"
    export PROV_FORGE_URL=""
    prov_seat_binding amiral
    [ "$PROV_SEAT_BINDING" = agree ]
  '
  [ "$status" -eq 0 ]
}

# ─── forge_curl — le jeton voyage par stdin ───────────────────────────────────────────────────────
stub_curl() { # enregistre argv et stdin de l appel, repond 200
  export STUB_BIN="$BATS_TEST_TMPDIR/bin" STUB_ARGV="$BATS_TEST_TMPDIR/argv" STUB_STDIN="$BATS_TEST_TMPDIR/stdin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
cat > "$STUB_STDIN"
echo 200
STUB
  chmod +x "$STUB_BIN/curl"
}

@test "forge_curl : le jeton part sur STDIN (-K -), jamais dans argv" {
  # `-H "Authorization: token $tok"` rend le jeton lisible dans /proc de tout l hote pendant
  # l appel (6-141). Le mur I2 (idiom_walls.bats) interdit la forme ; ce temoin pinne l autre.
  stub_curl
  printf 'SECRET-TOKEN\n' > "$BATS_TEST_TMPDIR/tok"
  module_sh '
    PATH="$STUB_BIN:$PATH"
    out="$(forge_curl "$BATS_TEST_TMPDIR/tok" -s -m 10 http://forge.test/api/v1/x)"
    [ "$out" = 200 ]
  '
  [ "$status" -eq 0 ]
  refute grep -q 'SECRET-TOKEN' "$STUB_ARGV"
  grep -qx -- '-K' "$STUB_ARGV"
  grep -qx 'http://forge.test/api/v1/x' "$STUB_ARGV"
  grep -qx 'header = "Authorization: token SECRET-TOKEN"' "$STUB_STDIN"
}

@test "forge_curl sans jeton : requete ANONYME — stdin vide, aucun Authorization nulle part" {
  stub_curl
  module_sh '
    PATH="$STUB_BIN:$PATH"
    forge_curl "$BATS_TEST_TMPDIR/absent" -s http://forge.test/api/v1/x >/dev/null
    forge_curl "" -s http://forge.test/api/v1/y >/dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_STDIN" ]
  refute grep -qi 'authorization' "$STUB_ARGV" "$STUB_STDIN"
}

# ─── arch_tag — une seule table d architecture ────────────────────────────────────────────────────
stub_dpkg() { # stub_dpkg <arch> — un dpkg qui repond <arch> ; vide = pas de dpkg du tout
  export STUB_BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUB_BIN"; rm -f "$STUB_BIN/dpkg"
  [[ -n "$1" ]] || return 0
  printf '#!/usr/bin/env bash\n[ "$1" = --print-architecture ] && echo %s\n' "$1" > "$STUB_BIN/dpkg"
  chmod +x "$STUB_BIN/dpkg"
}

@test "arch_tag : amd64 se dit x64 chez node, amd64 chez debian, et raw rend dpkg tel quel" {
  stub_dpkg amd64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ "$(arch_tag node)" = x64 ] && [ "$(arch_tag debian)" = amd64 ] && [ "$(arch_tag raw)" = amd64 ]'
  [ "$status" -eq 0 ]
  stub_dpkg arm64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ "$(arch_tag node)" = arm64 ] && [ "$(arch_tag debian)" = arm64 ]'
  [ "$status" -eq 0 ]
}

@test "arch_tag : une arch non epinglee rend VIDE — jamais un repli, jamais uname" {
  stub_dpkg riscv64
  module_sh 'PATH="$STUB_BIN:$PATH"; [ -z "$(arch_tag node)" ] && [ -z "$(arch_tag debian)" ] && [ "$(arch_tag raw)" = riscv64 ]'
  [ "$status" -eq 0 ]
  stub_dpkg ""
  module_sh 'PATH="$STUB_BIN"; [ -z "$(arch_tag node)" ] && [ -z "$(arch_tag raw)" ]'
  [ "$status" -eq 0 ]
}

# ─── set_diff / env_field — deux lectures qui ne meurent pas ─────────────────────────────────────

@test "set_diff : les lignes de b absentes de a — trie, dedoublonne, ignore le vide" {
  # `comm` sur des entrees non triees rend un resultat faux sans un mot (GNU) ; set_diff trie.
  module_sh '
    out="$(set_diff $'"'"'b\na\n\nc'"'"' $'"'"'c\nd\na\nd\n'"'"')"
    [ "$out" = d ]
    [ -z "$(set_diff $'"'"'x\ny'"'"' $'"'"'y\nx'"'"')" ]
    [ "$(set_diff "" $'"'"'z\nz'"'"')" = z ]
  '
  [ "$status" -eq 0 ]
}

@test "env_field : fichier absent = vide et 0 ; cle repetee = la DERNIERE, comme un source" {
  printf 'A=1\nB=premier\nB=dernier\n' > "$BATS_TEST_TMPDIR/e.env"
  module_sh '
    [ -z "$(env_field /nonexistent/x.env A)" ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" A)" = 1 ]
    [ "$(env_field "$BATS_TEST_TMPDIR/e.env" B)" = dernier ]
    [ -z "$(env_field "$BATS_TEST_TMPDIR/e.env" C)" ]
  '
  [ "$status" -eq 0 ]
}

@test "read_token : absent = vide, rc 0 et AUCUN message — le shell ne crie pas l absence du fichier" {
  # `tr < fichier 2>/dev/null` echoue sur la redirection d'entree avant que stderr soit detourne :
  # bash imprime lui-meme « No such file » sur le vrai stderr. Un jeton absent est une REPONSE.
  printf '  jeton \n' > "$BATS_TEST_TMPDIR/t"
  module_sh '
    out="$(read_token /nonexistent/jeton 2>&1)"; [ -z "$out" ]
    out="$(read_token "" 2>&1)"; [ -z "$out" ]
    [ "$(read_token "$BATS_TEST_TMPDIR/t")" = jeton ]
  '
  [ "$status" -eq 0 ]
}

# ─── p_fact : LE MEME FAIT, POUR UNE MACHINE ────────────────────────────────────────────────────
#
# Les `p_*` racontent a un humain ; `p_fact` depose un fait nu pour un appelant qui doit DECIDER.
# Ce que ces temoins gardent, c'est qu'il ne peut RIEN casser chez son appelant : ni sa sortie, ni
# son verdict, ni son processus. Un canal de faits qui tue le module qui l'alimente serait pire que
# pas de canal du tout.

@test "p_fact : SANS le fichier, il n ecrit rien et ne dit rien — un module reste lisible seul" {
  module_sh '
    out="$(p_fact substrat wsl 2>&1)"
    [ -z "$out" ]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "p_fact : AVEC le fichier, une ligne nom=valeur par fait, dans l ordre" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact substrat wsl
    p_fact docker oui
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${lines[0]}" = "substrat=wsl" ]
  [ "${lines[1]}" = "docker=oui" ]
}

@test "p_fact : la valeur garde ses espaces — une raison de refus est une phrase" {
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact docker_why 'le daemon repond mais pas a cet utilisateur'
    p_fact docker_why2 le daemon repond pas
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${lines[0]}" = "docker_why=le daemon repond mais pas a cet utilisateur" ]
  # Sans quotes non plus : la valeur est TOUT ce qui suit le nom, pas le seul mot suivant.
  [ "${lines[1]}" = "docker_why2=le daemon repond pas" ]
}

@test "p_fact : un appel a UN seul argument n ecrit rien et ne tue pas l appelant" {
  # Un fait sans valeur n'est pas un fait. Il ne doit pas produire « nom= » — une ligne qu'un
  # appelant lirait comme « mesure faite, resultat vide » au lieu de « pas de mesure ».
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_fact orphelin
    p_fact substrat wsl
  "
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/facts"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "substrat=wsl" ]
}

@test "LE PIEGE : un fichier de faits INECRIVABLE ne tue pas le module et ne crie pas" {
  # ⚠ L'ORDRE DES REDIRECTIONS EST LOAD-BEARING, et c'est la troisieme fois que ce corpus l'epingle
  # (`prov_journal_acc`, `read_token`, ici). Elles se traitent de GAUCHE A DROITE : `2>/dev/null`
  # ecrit APRES `>>` arrive trop tard, l'ouverture a deja echoue et le shell a deja imprime son
  # « No such file » sur le VRAI stderr — au milieu du rapport de l'appelant.
  #
  # Et sous `set -e`, une redirection qui echoue tue le module. Un canal optionnel qui abat le
  # provisionnement parce que /tmp est plein serait exactement l'inverse de ce qu'il achete.
  module_sh "
    export PROV_FACTS_FILE='/nonexistent/repertoire/facts'
    out=\$(p_fact substrat wsl 2>&1)
    [ -z \"\$out\" ]
    p_ok 'le module continue apres'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"le module continue apres"* ]]
}

@test "p_fact ne renverse JAMAIS le verdict qu il rapporte" {
  # Meme motif que le `return 0` de `p_ok` : sans lui, le rc est celui du `printf`, et un
  # `p_fact … || p_drift` annoncerait une derive que rien ne justifie. Ici on mesure la forme la
  # plus commune — un module conforme qui depose ses faits doit sortir 0.
  module_sh "
    export PROV_FACTS_FILE='$BATS_TEST_TMPDIR/facts'
    p_ok 'conforme'
    p_fact substrat wsl
    verdict_check
  "
  [ "$status" -eq 0 ]
}

# ─── prov_dans_la_copie — LA COPIE POSEE N EST PAS UN ARBRE DE BUILD ────────────────────────────
#
# ⚠ TROIS MODULES ONT TENTE D Y BATIR, MESURE DU 2026-09-02 SUR DEUX BANCS INDEPENDANTS (2006 et
# 2007), sur un apply rejoue depuis `/opt/lcars/deploy/provision` — le geste NOMINAL du
# convergeur :
#     FAIL 44-media:      npm run build (/opt/lcars/assets/github.io)
#     FAIL 48-forge-host: mix deps.get (/opt/lcars/services)
#     FAIL 60-deploy:     source runtime introuvable: /opt/lcars/services
#
# Et le premier ne faisait pas qu echouer : `npm ci` a INSTALLE 176 Mo sous /opt/lcars avant de
# rater son build. La copie n est pas seulement incapable de batir — la laisser essayer la pollue.
#
# LES DEUX QUESTIONS SONT DISTINCTES : la LIVRAISON dit s il y a quelque chose a batir, l EMPLACEMENT
# dit si on est a un endroit ou l on PEUT batir. Les trois modules savaient lire la premiere.
@test "prov_dans_la_copie : vrai quand le rail tourne DEPUIS la racine qu il a posee" {
  module_sh '
    D="$BATS_TEST_TMPDIR/copie"; mkdir -p "$D"
    repo_root() { echo "$D"; }
    PROV_ROOT="$D"
    prov_dans_la_copie
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis l arbre de travail — c est la ou l on batit" {
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/travail" "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/travail"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prov_dans_la_copie : faux depuis un SOUS-repertoire de la racine — c est l egalite qui compte" {
  # Un `case "$root" in "$PROV_ROOT"*)` aurait rendu vrai pour /opt/lcars-autre-chose. On compare
  # des chemins entiers, comme partout ailleurs dans cette lib.
  module_sh '
    mkdir -p "$BATS_TEST_TMPDIR/opt"
    repo_root() { echo "$BATS_TEST_TMPDIR/opt-voisin"; }
    PROV_ROOT="$BATS_TEST_TMPDIR/opt"
    rc=0; prov_dans_la_copie || rc=$?
    [ "$rc" -eq 1 ]
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ─── ensure_mode : un bit special en trop se RETIRE (DI-09, lot 11) ────────────────────────────
# Le mode numerique demande est le mode ENTIER : un setgid herite d'un `mkdir` sous un parent 2775
# n'est pas « presque 0755 », c'est un autre mode, et chmod ne le retire que si on le lui dit.
@test "ensure_mode : un setgid herite est RETIRE quand le mode demande ne le porte pas — et POSE quand il le porte" {
  local d="$BATS_TEST_TMPDIR/parent"
  mkdir -p "$d/enfant"; chmod 2775 "$d/enfant"
  [ "$(stat -c %a "$d/enfant")" = 2775 ]
  run bash -c ". '$LIB'; PROV_MODULE_TAG=t; ensure_mode '$d/enfant' 0755"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$d/enfant")" = 755 ]
  [[ "$output" == *"POSÉ"* ]]
  run bash -c ". '$LIB'; PROV_MODULE_TAG=t; ensure_mode '$d/enfant' 2775"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$d/enfant")" = 2775 ]
}

# ─── product_tree : l'arbre du produit, lisible par TOUT LE MONDE (relecture hostile 2026-09-04) ─
# Un checkout porte `runtime/` et rien nomme `services/` a sa racine ; une machine posee porte
# `services/` a plat (et `runtime/` est le PREFIX de la release, 0750 root:fleet). Le discriminant
# se lit par un stat sur un ENFANT DIRECT de la racine, jamais en descendant dans `runtime/`, qu'un
# daemon hors du groupe fleet ne peut pas ouvrir.
pt_root() { # pt_root <racine> -> ce que product_tree rend avec une lib copiee sous <racine>/deploy/lib
  mkdir -p "$1/deploy/lib"; cp "$LIB" "$1/deploy/lib/provision-lib.sh"; cp "$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh" "$1/deploy/lib/"
  PROVISION_LIB="$1/deploy/lib/provision-lib.sh" bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; product_tree'
}
@test "product_tree : un checkout (runtime/ present, pas de services/ a la racine) → runtime/" {
  local r="$BATS_TEST_TMPDIR/co"; mkdir -p "$r/runtime/etc"
  [ "$(pt_root "$r")" = "$r/runtime" ]
}
@test "product_tree : une machine posee (services/ a plat, runtime/ = la release) → la racine" {
  local r="$BATS_TEST_TMPDIR/posee"; mkdir -p "$r/runtime/rel/lcars_fleet" "$r/services/human.d" "$r/etc"
  [ "$(pt_root "$r")" = "$r" ]
}
@test "product_tree : la release ILLISIBLE (0750 root:fleet, lecteur hors du groupe) ne change pas la reponse" {
  [ "$(id -u)" -ne 0 ] || skip "root lit tout"
  local r="$BATS_TEST_TMPDIR/posee2"; mkdir -p "$r/runtime/rel/lcars_fleet" "$r/services/human.d"
  chmod 0000 "$r/runtime"
  local got; got="$(pt_root "$r")"; chmod 0755 "$r/runtime"
  [ "$got" = "$r" ]
}

# ─── DI-13 : l'appartenance a un groupe se capture puis se teste — jamais `| grep -qx` ─────────

@test "prov_in_group : membre de son groupe primaire → 0 ; d'un groupe qui n'existe pas → 1" {
  module_sh 'prov_in_group "$(id -un)" "$(id -gn)" && echo DEDANS'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDANS"* ]]
  module_sh 'prov_in_group "$(id -un)" "groupe-decor-inexistant-di13" || echo DEHORS'
  [[ "$output" == *"DEHORS"* ]]
}

@test "prov_in_group : un groupe dont le nom est un PREFIXE d'un autre n'est pas pris pour lui" {
  # `[[ " $groups " == *" $grp "* ]]` : les espaces de bordure font le mot entier, comme `grep -x`.
  module_sh 'id() { echo "fleet-console fleet_bis"; }; prov_in_group x fleet || echo DEHORS; prov_in_group x fleet_bis && echo DEDANS'
  [[ "$output" == *"DEHORS"* ]]
  [[ "$output" == *"DEDANS"* ]]
}

@test "prov_in_group : un compte inconnu → 1, sans bruit sur stderr" {
  # `run` capture stdout ET stderr : une sortie reduite au seul mot prouve le silence.
  module_sh 'if prov_in_group compte-decor-inexistant-di13 fleet; then echo DEDANS; else echo DEHORS; fi'
  [ "$output" = "DEHORS" ]
}

@test "prov_pgrep_pattern : le motif matche la cible et JAMAIS la commande qui le porte" {
  local m; m="$(bash -c "source '$LIB' >/dev/null 2>&1; prov_pgrep_pattern zorglub-$$")"
  [ "$m" = "[z]orglub-$$" ]
  # le porteur est le `bash -c` lui-meme : son argv contient le motif. Avec le crochet, pgrep ne
  # le voit pas ; avec la chaine nue, il SE voit — c est le piege que le motif ferme.
  run bash -c "pgrep -f '$m' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == *"PAS-VU"* ]]
  run bash -c "pgrep -f 'zorglub-$$' >/dev/null && echo VU || echo PAS-VU"
  [[ "$output" == "VU" ]]
}

# ─── LA FRONTIERE SYSTEME/HUMAIN : FAIL-CLOSED, ET LA MEME REGLE QUE LE PROTOCOLE DU PRODUIT ────
#
# ⚖ user 2026-09-05 (lot 14, solution A + C + E de `17-DEUX-OUVERTS.md`). La lib devinait
# `1000`/`60000` (`_uid_bound … <defaut>`) quand login.defs etait illisible ; le BEAM refuse de
# booter dans ce cas, et `console-humans.sh` ne rend aucune liste. La regle est desormais celle de
# `runtime/services/lib/human-protocol.sh` — RE-ECRITE ici (la lib ne source pas de code du produit,
# et 22 joue avant 62), donc tenue egale par CE temoin : meme matrice, memes verdicts, meme phrase.
#
# Un `id` de decor (zoe 1001, admiral 1000 = le siege, svc 999, nobody 65534) : aucun compte de la
# machine n'est lu. Le siege est pose par la variable, le fichier est absent (MUR I9).
uid_rule_decor() {
  export LCARS_SYSADMIN_UID=1000
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$PASSWD_DEFS"
  export PASSWD_FILE="$BATS_TEST_TMPDIR/passwd"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'svc:x:999:999::/nonexistent:/usr/sbin/nologin' \
    'admiral:x:1000:1000::/home/admiral:/bin/bash' 'zoe:x:1001:1001::/home/zoe:/bin/bash' \
    'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin' > "$PASSWD_FILE"
  UBIN="$BATS_TEST_TMPDIR/ubin"; mkdir -p "$UBIN"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in *zoe*) echo 1001 ;; *admiral*) echo 1000 ;; *svc*) echo 999 ;; *nobody*) echo 65534 ;; *) exit 1 ;; esac' \
    > "$UBIN/id"
  chmod 0755 "$UBIN/id"
  PROTO="$BATS_TEST_DIRNAME/../../../runtime/services/lib/human-protocol.sh"
  [ -f "$PROTO" ] || { echo "protocole du produit introuvable : $PROTO" >&2; return 1; }
}

lib_verdict() { # lib_verdict <login> -> "rc|remede" selon la lib de l'installeur
  bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' PROVISION_MODULE=test-mod; source '$LIB' >/dev/null 2>&1
    is_fleet_human '$1' 2>/dev/null; rc=\$?; printf '%s|%s' \"\$rc\" \"\$PROV_UID_BOUNDS_WHY\""
}

proto_verdict() { # proto_verdict <login> -> "rc|remede" selon le protocole du produit
  bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' LCARS_HUMAN_PROTOCOL_HOST=1
    export LCARS_MODULE_PROTOCOL='$(dirname "$PROTO")/module-protocol.sh' LCARS_PRIVATE_DIR='$BATS_TEST_TMPDIR'
    . '$PROTO'
    is_fleet_human '$1' 2>/dev/null; rc=\$?; printf '%s|%s' \"\$rc\" \"\$UID_BOUNDS_WHY\""
}

@test "uid: zoe est un humain ; svc (sous UID_MIN), nobody (au-dessus de UID_MAX) et le siege ne le sont pas" {
  uid_rule_decor
  [ "$(lib_verdict zoe)" = "0|" ]
  [ "$(lib_verdict svc)" = "1|" ]
  [ "$(lib_verdict nobody)" = "1|" ]
  [ "$(lib_verdict admiral)" = "1|" ]
}

@test "uid: bornes ILLISIBLES — is_fleet_human rend non a tout le monde, fleet_humans ne rend personne, le remede est dit UNE FOIS" {
  uid_rule_decor
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  run bash -c "set -uo pipefail; export PATH='$UBIN:$PATH' PROVISION_MODULE=test-mod; source '$LIB' >/dev/null 2>&1
    is_fleet_human zoe && echo ZOE_OUI
    echo \"pop=[\$(fleet_humans | paste -sd, -)]\"
    fleet_humans; fleet_humans
    echo FIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZOE_OUI"* ]]
  [[ "$output" == *"pop=[]"* ]]
  [[ "$output" == *"FIN"* ]]
  [[ "$output" == *"UID_MIN illisible dans $PASSWD_DEFS"* ]]
  [[ "$output" == *"repare $PASSWD_DEFS"* ]]
  # UNE fois : dit par `is_fleet_human` dans le processus, la trace est heritee par le `$( )` de
  # `pop=` comme par les deux appels suivants — quatre lectures, un remede.
  [ "$(grep -c "n'est pas etablie" <<<"$output")" -eq 1 ]
  refute grep -qE '(^|[^0-9])1000([^0-9]|$)' <<<"$output"
}

@test "uid: UID_MAX absent du fichier n'etablit pas la frontiere non plus — nobody ne passe jamais par un defaut" {
  uid_rule_decor
  printf 'UID_MIN\t1000\n' > "$PASSWD_DEFS"
  [ "$(lib_verdict nobody)" = "1|la frontiere systeme/humain n'est pas etablie (UID_MAX illisible dans $PASSWD_DEFS) — la borne est declaree par le systeme, pas par ce processus : repare $PASSWD_DEFS" ]
}

@test "uid: LA REGLE EST CELLE DU PROTOCOLE DU PRODUIT — meme matrice, memes verdicts, meme phrase" {
  # Le temoin d'egalite des deux corps. Quatre fichiers login.defs (lisible ; absent ; sans UID_MAX ;
  # plancher a 2000) × quatre logins : la lib et le protocole doivent repondre pareil, remede compris.
  #
  # LECTURE A TRAVERS LA COUTURE deploy→runtime, ASSUMEE (lot 15). Ce temoin compare DEUX CORPS par
  # nature — la copie de la lib et sa source, `runtime/services/lib/human-protocol.sh` — donc il ne
  # peut pas vivre d'un seul cote. C'est une LECTURE au sens de la grille du chantier
  # deploy-independance (jamais un `source`, jamais un appel : la lib ne charge rien du produit), et
  # c'est la seule qui reste ici : les murs I18 sont scindes, chaque cote grep ses propres fichiers.
  # Hors matrice, deliberement : le siege INCONNU — la lib repond non a tout le monde, le protocole
  # ne garde pas ce cas ; c'est un ecart connu, nomme au rapport du lot 14, pas mesure ici.
  uid_rule_decor
  local variant login lib proto bad=0
  for variant in lisible absent sans-max plancher-2000; do
    case "$variant" in
      lisible)       printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
      absent)        export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs" ;;
      sans-max)      printf 'UID_MIN\t1000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
      plancher-2000) printf 'UID_MIN\t2000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs" ;;
    esac
    for login in zoe svc nobody admiral; do
      lib="$(lib_verdict "$login")"; proto="$(proto_verdict "$login")"
      [ "$lib" = "$proto" ] || { echo "$variant/$login : lib=« $lib » protocole=« $proto »" >&2; bad=1; }
    done
  done
  [ "$bad" -eq 0 ]
  # GARDE D'INSTRUMENT : la matrice a bien parle — le cas absent porte un remede, le cas lisible aucun.
  export PASSWD_DEFS="$BATS_TEST_TMPDIR/nulle-part/login.defs"
  [[ "$(lib_verdict zoe)" == "1|la frontiere"* ]]
  printf 'UID_MIN\t1000\nUID_MAX\t60000\n' > "$BATS_TEST_TMPDIR/login.defs"; export PASSWD_DEFS="$BATS_TEST_TMPDIR/login.defs"
  [ "$(lib_verdict zoe)" = "0|" ]
}

@test "apt_ensure : apt-get recoit un DELAI et des reprises — un miroir mort se dit, il ne suspend pas l'installeur (banc 2003, 2026-09-05)" {
  local b="$BATS_TEST_TMPDIR/apt"; mkdir -p "$b"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not-installed"' > "$b/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "'"$b"'/argv"' \
    'case " $* " in *" indextargets "*) echo "http://archive.ubuntu.com/ubuntu/dists/x/InRelease"; exit 0;; esac' 'exit 100' > "$b/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *https://archive.ubuntu.com*) exit 0;; *) exit 28;; esac' > "$b/curl"
  chmod 0755 "$b"/*
  run bash -c "set -uo pipefail; export PATH=\"$b:$PATH\"; . '$LIB' >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0; apt_ensure jq; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  # le delai et les reprises sont sur la ligne d'apt-get update
  grep -qE 'Acquire::http::Timeout=30' "$b/argv"
  grep -qE 'Acquire::Retries=2' "$b/argv"
  grep -qE '^update .*-o Acquire' "$b/argv"   # le verbe d abord : les doublures lisent \$1
  # le diagnostic nomme le miroir ET le remede — http mort, https vivant
  [[ "$output" == *"archive.ubuntu.com INJOIGNABLE en http"* ]]
  [[ "$output" == *"passe tes sources apt en https"* ]]
}

@test "apt_ensure : miroir vivant mais apt en echec — le diagnostic ne blame pas le reseau" {
  local b="$BATS_TEST_TMPDIR/apt2"; mkdir -p "$b"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "not-installed"' > "$b/dpkg-query"
  printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" indextargets "*) echo "http://archive.ubuntu.com/ubuntu/dists/x/InRelease"; exit 0;; esac' 'exit 100' > "$b/apt-get"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$b/curl"
  chmod 0755 "$b"/*
  run bash -c "set -uo pipefail; export PATH=\"$b:$PATH\"; . '$LIB' >/dev/null 2>&1; PROV_CHANGED=0 PROV_FAILED=0; apt_ensure jq; echo rc=\$?"
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"le miroir http://archive.ubuntu.com repond"* ]]
  refute_out 'INJOIGNABLE' <<<"$output"
}
