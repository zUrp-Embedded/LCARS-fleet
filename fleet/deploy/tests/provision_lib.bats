#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/provision_lib.bats
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

setup() {
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export LIB
  [ -f "$LIB" ]
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
    ! grep -q "old-content" "$f"
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
  local lib="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  grep -qE '^\s*\( cd "\$home" && runuser -u "\$PROV_HUMAN"' "$lib"
  # Et le `cd` est dans un SOUS-SHELL : sans les parentheses, le module appelant repartirait avec
  # un cwd change sous lui, ce qui echangerait un defaut contre un autre, plus difficile a voir.
  grep -qE '^\s*\( cd .* \)$' "$lib"
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

@test "6-130: le verrou vit dans un dossier 0700 possede par l appelant" {
  module_sh '
    lock="$(prov_lock_path)"
    dir="$(dirname "$lock")"
    [ "$(stat -c %a "$dir")" = "700" ]
    [ "$(stat -c %u "$dir")" = "$(id -u)" ]
  '
  [ "$status" -eq 0 ]
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
  module_sh '
    detect_substrate() { echo wsl; }
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
    detect_substrate() { echo wsl; }
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
    detect_substrate() { echo linux; }
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
    detect_substrate() { echo linux; }
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

@test "run_step: un succes ne laisse AUCUN fichier derriere lui" {
  before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  module_sh 'run_step "ok" -- bash -c "echo rien; sleep 1.1"'
  [ "$status" -eq 0 ]
  after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'prov-out.*' 2>/dev/null | wc -l)"
  [ "$after" -eq "$before" ]
}

@test "run_step --ok N : un code tolere n'est pas un echec, et il NE TUE PAS l'appelant" {
  # ⚠ LE DEFAUT QUE CE TEMOIN GARDE ETAIT ECRIT, COMMENTE, ET INATTEIGNABLE. `etc/install.sh` rend 3
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

@test "lan_addr tient son contrat « vide si indeterminable » — meme sans `ip`" {
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
