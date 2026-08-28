#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/install_journal.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — le JOURNAL : ce qui a ete pose sur CETTE machine
#
# ─── LE FAIT QU'AUCUN FICHIER STATIQUE NE PEUT PORTER ───────────────────────────────────────────
#
# `system.manifest` dit ce que le provisionnement a le DROIT de poser : statique, versionne, le meme
# partout. Le journal dit ce qu'il A pose ICI — et la seule chose qui compte vraiment dedans est la
# separation `apt_installed` / `apt_already`.
#
# ⚠ ELLE N'EST CONNAISSABLE QU'AVANT L'INSTALL. Une seconde plus tard, `dpkg -s` repond « present »
# pour les deux listes et plus rien ne distingue ce que LCARS a pose de ce que l'operateur avait
# deja. Un uninstall qui l'ignore retire des paquets de quelqu'un d'autre — pire que d'en laisser.
#
# ⚠ ET LE CANAL EST UN FICHIER, PARCE QUE LES MODULES SONT DES PROCESSUS. Le runner ouvre
# l'accumulateur avant la boucle, les modules y notent, il le scelle apres. Meme lecon que
# `forge.url` : mesure du 2026-08-18, deux modules en derive parce qu'on croyait qu'un `export`
# traversait d'un module a l'autre.

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  RUNNER="$BATS_TEST_DIRNAME/../provision"
  [ -f "$LIB" ] && [ -f "$RUNNER" ]

  export PROVISION_LIB="$LIB"
  export PROVISION_MODULE=test-journal
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  ACC="$BATS_TEST_TMPDIR/acc"
}

# Sourcer la lib et jouer une expression dedans.
lib() { run bash -c "set -euo pipefail; . '$LIB' >/dev/null 2>&1; $1"; }

code() { grep -vE '^\s*#' "$1"; }

@test "MUET sans accumulateur — un appelant n'a jamais a savoir si le journal existe" {
  # `doctor`, un module joue nu, un temoin : aucun n'ouvre d'accumulateur. La note doit alors etre
  # sans effet ET sans echec. Une fonction de tracage qui fait tomber son appelant est un piege.
  lib 'prov_journal_note apt_installed socat && echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "une note sans valeur ne s'ecrit pas — une clef seule ne dit rien" {
  lib "PROV_JOURNAL_ACC='$ACC'; prov_journal_note apt_installed; echo \$?"
  [ "$status" -eq 0 ]
  [ ! -s "$ACC" ]
}

@test "la note s'ecrit : une ligne, une clef, ses valeurs" {
  lib "PROV_JOURNAL_ACC='$ACC'; prov_journal_note apt_installed socat jq"
  [ "$status" -eq 0 ]
  grep -qx 'apt_installed socat jq' "$ACC"
}

@test "un accumulateur illisible ne fait PAS tomber l'appelant" {
  # Le journal RACONTE, il ne decide pas. Une perte de trace se dit ; elle ne renverse pas un
  # verdict que vingt-cinq modules viennent de rendre.
  lib "PROV_JOURNAL_ACC='/proc/nonexistent/acc'; prov_journal_note apt_installed socat && echo survecu"
  [ "$status" -eq 0 ]
  [ "$output" = "survecu" ]
}

@test "apt_ensure SEPARE les deux listes, et le fait AVANT d'installer" {
  # Le coeur du fichier. On double `dpkg` : `git` est deja la, `socat` non.
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  # ⚠ LA DOUBLURE REPOND AUSSI A CE QUE LA LIB DEMANDE AU SOURCE. Reduite au seul `-s`, elle rendait
  # une chaine VIDE sur `--print-architecture` et la lib mourait avant le premier test — un decor
  # qui casse ce qu'il devait seulement observer.
  cat > "$bin/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) echo amd64; exit 0 ;;
  -s) case "$2" in git|curl) exit 0 ;; *) exit 1 ;; esac ;;
  *) exit 0 ;;
esac
SH
  # `apt-get` ne doit jamais tourner pour de vrai : s'il est appele, il TRACE et ment sur le succes.
  cat > "$bin/apt-get" <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >> "${APT_TRACE:?}"
exit 0
SH
  chmod +x "$bin/dpkg" "$bin/apt-get"
  export APT_TRACE="$BATS_TEST_TMPDIR/apt.trace"; : > "$APT_TRACE"

  # ⚠ GUILLEMETS DOUBLES SUR LE PATH, ET CE N'EST PAS DU STYLE. En simples, `$PATH` ne s'expanse pas :
  # on écrase le PATH entier par une chaîne littérale, `dirname` disparaît, et la lib meurt à son
  # `source` — sur une ligne qui n'a rien à voir avec ce qu'on mesure. Mesuré le 2026-08-22 : la
  # doublure ne cassait pas la lib, elle cassait le shell.
  run bash -c "set -euo pipefail
    export PATH=\"$bin:\$PATH\" PROV_JOURNAL_ACC='$ACC' APT_TRACE='$APT_TRACE'
    . '$LIB' >/dev/null 2>&1
    apt_ensure git socat curl >/dev/null 2>&1 || true
    cat '$ACC'"
  [[ "$output" == *"apt_already git curl"* ]]
  [[ "$output" == *"apt_installed socat"* ]]
  # et `git`/`curl` ne partent JAMAIS a l'install : c'est ce que la separation protege
  refute grep -q 'install.*git' "$APT_TRACE"
}

@test "la separation est notee AVANT l'appel a apt — apres, elle n'existe plus" {
  # ⚠ L'ORDRE EST LE FOND. Une seconde apres l'install, `dpkg -s` repond « present » pour les deux
  # listes : la distinction est perdue pour toujours. La noter apres serait noter une egalite.
  local body; body="$(code "$LIB" | sed -n '/^apt_ensure()/,/^}/p')"
  local n_note n_apt
  n_note="$(grep -n 'prov_journal_note apt_already' <<<"$body" | head -1 | cut -d: -f1)"
  n_apt="$(grep -n 'apt-get install' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_note" ] && [ -n "$n_apt" ]
  [ "$n_note" -lt "$n_apt" ]
}

@test "le runner n'ouvre l'accumulateur QUE sur apply" {
  # Un `doctor` ne pose rien. Lui faire ecrire un journal ferait raconter a la machine une pose qui
  # n'a pas eu lieu — et ce journal servirait ensuite a desinstaller.
  local body; body="$(code "$RUNNER")"
  grep -q 'PROV_JOURNAL_ACC="\$(mktemp' <<<"$body"
  grep -B2 'PROV_JOURNAL_ACC="\$(mktemp' <<<"$body" | grep -q 'CMD" == "apply"'
  grep -q 'CMD" == "apply" && -n "\${PROV_JOURNAL_ACC' <<<"$body"
}

@test "le journal se scelle AVANT le recap, et ne peut pas renverser un verdict" {
  local body; body="$(code "$RUNNER")"
  local n_seal n_recap
  n_seal="$(grep -n 'JOURNAL_FILE"' <<<"$body" | head -1 | cut -d: -f1)"
  n_recap="$(grep -n 'provision \$CMD — substrat' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_seal" ] && [ -n "$n_recap" ]
  [ "$n_seal" -lt "$n_recap" ]
  # une ecriture ratee se DIT, elle ne `die` pas
  grep -q 'journal NON écrit' <<<"$body"
  refute grep -qE 'journal.*\|\| die' <<<"$body"
}

@test "le repli DEDOUBLONNE — apt_ensure est appelee par plusieurs modules" {
  printf 'apt_installed socat jq\napt_already git\napt_installed jq gh\n' > "$ACC"
  run awk '{ k=$1; $1=""; sub(/^ /,""); acc[k]=acc[k] " " $0 }
       END { for (k in acc) {
               n=split(acc[k], w, " "); delete seen; out=""
               for (i=1;i<=n;i++) if (w[i]!="" && !(w[i] in seen)) { seen[w[i]]=1; out=out " " w[i] }
               printf "%-13s%s\n", k, out } }' "$ACC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"socat jq gh"* ]]
  [ "$(grep -c 'jq' <<<"$output")" -eq 1 ]
}

@test "le journal se declare MESURE, jamais declaration" {
  # Les deux fichiers se ressemblent et disent des choses opposees. Celui qui les confond
  # desinstalle depuis une intention au lieu d'un fait.
  local body; body="$(code "$RUNNER")"
  grep -q 'mesure, pas declaration' <<<"$body"
  grep -q 'data, not code' "$BATS_TEST_DIRNAME/../system.manifest"
}

@test "le chemin du journal a une couture, et son defaut vit AVEC l'etat machine" {
  # `/etc/lcars` porte deja `host-consent`, `services.env` et `deck-oidc.json` — l'etat machine qui
  # n'est pas le runtime. La phase B du chantier empreinte deplacera les quatre ensemble.
  code "$RUNNER" | grep -q 'LCARS_JOURNAL_FILE:-/etc/lcars/install.journal'
  grep -qE '^dir +/etc/lcars ' "$BATS_TEST_DIRNAME/../system.manifest"
}
