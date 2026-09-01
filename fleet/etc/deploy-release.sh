#!/usr/bin/env bash
# SOURCE: etc/deploy-release.sh
# AUTHOR: starfleet
# STARDATE: 2026-06-22
# STATUS: v2 deployment — builds the prod release and puts EVERYTHING under $PREFIX (default
#         /opt/lcars/runtime). Self-contained: the runtime runs WITHOUT the repo (bundled priv, embedded
#         ERTS). Idempotent, and CRASH-SAFE: a build or copy failure never destroys the live install.
#
# Three-zone model: SOURCE (this repo, build only) → INSTALL ($PREFIX, RO, system-owned) → STATE
# (~/.lcars, per-human, RW). PREFIX defaults to /opt/lcars/runtime.
# ⚠ THIS PARAGRAPH DESCRIBED A MOVE THAT HAS SINCE HAPPENED, IN THE FUTURE TENSE. It read: "`v2`
# means cohabiting with the v1 runtime (/local/LCARS); eventually PREFIX=/local/lcars, which is one
# `mv` plus a symlink repoint". The move landed elsewhere — under /opt/lcars, the vendor directory
# the norm reserves — and /local disappeared with it. A plan kept in the present tense after it was
# carried out reads as a plan still to come.
#
# TWO env knobs, not one — the header used to claim PREFIX was the only parameter, and it is not:
#   LCARS_INSTALL_PREFIX    where everything is installed (default /opt/lcars/runtime)
#   LCARS_INSTALL_LINK_DIR  where the PATH symlinks go (default /usr/local/bin)
#
# EXIT CODES — 0 install complete · 1 hard failure (nothing usable posted) · 3 RELEASE POSTED, PATH
# LINKS INCOMPLETE. The third exists because `link_fail` was set and never read: the script said
# `OK` and returned 0 while its PATH commands were absent, or still pointed at a PREVIOUS version
# (`ln -sf` failed, the old link survived, and the operator ran a release he believed was new).
# It is a FACT, not a verdict — a caller that wires the links itself is right to accept it, and
# `deploy/modules.d/60-deploy.sh` does exactly that: it runs this script AS THE HUMAN (who cannot
# write /usr/local/bin) and re-posts the symlinks as root right after. Standalone, 3 is a refusal.
# Deliberately hardcoded: the `fleet` group and the `lcars_fleet` release name (kept at the
# app collapse, cf. mix.exs). WHAT ships into bin/ is NOT code anymore: the list lives in
# etc/release.manifest (data — file, exec/noexec, optional `link`). The installer is blind to
# content; add or remove a shipped file THERE. (The old in-code list existed twice — here and in
# etc/README.md — and the copies had started to drift.)
#
# ATOMICITY: the old flow did `rm -rf $PREFIX/rel` then a multi-second `cp -a`, and overwrote each
# launcher in place. An error mid-copy lost the last good build; a reader mid-copy saw a mixed
# assembly. Now every replacement stages a sibling on the SAME filesystem, verifies it, then `mv`s it
# into place (an atomic rename at the directory-entry level) — keeping the previous generation as
# `<name>.prev` for rollback. The live target is never a half-copied tree.
#
# Usage: etc/deploy-release.sh                        # → /opt/lcars/runtime
#        LCARS_INSTALL_PREFIX=/x etc/deploy-release.sh
#        LCARS_INSTALL_LINK_DIR=~/bin etc/deploy-release.sh
set -euo pipefail

say() { echo "install: $*" >&2; }
die() { echo "install: ERREUR — $*" >&2; exit 1; }

# Atomic directory replace: stage `src` into a sibling of `dst` (same FS → rename is atomic), verify
# it holds `probe` (a relative path that must exist + be executable), then swap — moving any live `dst`
# aside to `dst.prev` first (rollback kept). A reader sees the OLD tree or the NEW tree under `dst`,
# never a partial one; a verify failure leaves the live install untouched.
atomic_swap_dir() {
  local src="$1" dst="$2" probe="$3"
  local stage="${dst}.staging.$$" prev="${dst}.prev"

  rm -rf "$stage"
  cp -a "$src" "$stage" || { rm -rf "$stage"; die "copie du build vers le staging echouee ($stage)"; }

  [[ -x "$stage/$probe" ]] || { rm -rf "$stage"; die "build stage invalide : $probe absent ou non-executable"; }

  # Two renames, ordered so `dst` is never a partial tree: move the old aside, move the new in. The
  # sliver between them is a clean absence (ENOENT), not a mixed assembly. rm the prior .prev first so
  # the rollback slot always holds exactly the generation we just replaced.
  rm -rf "$prev"
  [[ -e "$dst" ]] && mv "$dst" "$prev"
  mv "$stage" "$dst"
}

# Atomic file replace: copy to a sibling temp, then rename over `dst` (a single atomic rename — a reader
# sees the old file or the new file, never a truncated copy). No .prev for the small scripts (the
# release dir is the one worth a rollback slot).
atomic_swap_file() {
  local src="$1" dst="$2"
  local tmp="${dst}.new.$$"

  cp -a "$src" "$tmp" || { rm -f "$tmp"; die "copie de $(basename "$dst") vers le staging echouee"; }
  mv "$tmp" "$dst"
}

# Builds the prod release, TIED to the full gate on the SAME source tree. `mix release` only replays
# the contracts lock (mix.exs step) — the SHA in build-info identifies the artifact, it does not
# QUALIFY it (compile-strict / ExUnit / bats / topology / Dialyzer are not re-run at build). So this
# runs `mix gate` FIRST, a direct gate→build continuation: the bits installed are the bits the gate
# passed. LCARS_INSTALL_SKIP_GATE=1 is an explicit escape (an operator who just ran the gate) — it
# must be a stated choice, never the default. Runs in `runtime_dir`; dies on a red gate or build.
build_release() {
  local runtime_dir="$1"

  # ⚠ CETTE CONDITION ETAIT « UN BINAIRE EXISTE », ET RIEN D'AUTRE. Elle disait : « c'est un paquet,
  # pas un checkout ». C'est une DEDUCTION, et elle est fausse des que ce script tourne depuis un
  # clone — ce qui est le chemin nominal du rail poste, ou `60-deploy` l'appelle. Un `_build/prod/rel`
  # laisse par un `mix release` d'il y a trois semaines suffisait a sauter LE GATE ET LA
  # COMPILATION, et a poser cette release-la.
  #
  # ET LE GARDE D'EN FACE ETAIT DEFAIT EXACTEMENT QUAND IL SERVAIT. `60-deploy` verifie trois choses
  # avant de ne rien faire — sha deploye == HEAD, arbre `fleet` propre, release presente. Quand
  # l'une manque, il conclut « il faut batir » et delegue ICI... qui reutilisait le vieux build. Le
  # rail annonçait alors un deploiement du HEAD en ayant pose autre chose.
  #
  # LE DISCRIMINANT EST EXPLICITE, PAS DEDUIT. `pack.sh` ecrit `.source-revision` a la racine du
  # paquet (convention dont la SSoT est `PROV_SOURCE_STAMP`, dans `deploy/lib/provision-lib.sh` —
  # que ce script ne peut pas lire : il est autonome et ne source pas la lib du rail). Sa presence
  # DIT « paquet », au lieu de le deviner de l'absence d'un `.git` — un paquet detare dans un depot
  # aurait trompe la deduction.
  local rel="$runtime_dir/_build/prod/rel/lcars_fleet"
  if [[ -x "$rel/bin/lcars_fleet" ]]; then
    if [[ -f "$runtime_dir/../.source-revision" ]]; then
      echo "install: paquet — release batie par pack.sh (gate joue la-bas), ni gate ni compilation" >&2
      return 0
    fi
    local src_sha built_sha m
    src_sha="$(git -C "$runtime_dir" rev-parse --short HEAD 2>/dev/null || true)"
    m=("$rel"/lib/lcars_fleet-*/priv/api/build_info.txt)
    [[ -f "${m[0]}" ]] && built_sha="$(sed -n 's/^sha=//p' "${m[0]}" 2>/dev/null | head -1)"
    if [[ -n "$src_sha" && "$src_sha" == "${built_sha:-}" ]] \
       && git -C "$runtime_dir" diff --quiet HEAD -- . 2>/dev/null; then
      echo "install: release deja batie et ATTESTEE ($src_sha, arbre propre) — ni gate ni compilation" >&2
      return 0
    fi
    echo "install: un _build/prod/rel existe mais n'atteste pas cette source (build ${built_sha:-inconnu} vs HEAD ${src_sha:-inconnu}) — on rebatit" >&2
  fi

  # `set -e` explicit in the subshell: bats' `run` disables errexit in the caller and a subshell
  # inherits that, so each critical command is ALSO guarded with `|| exit` — a red gate must stop the
  # build regardless of the caller's errexit state.
  (
    set -e
    cd "$runtime_dir"
    MIX_ENV=prod mix deps.get >/dev/null || exit 1

    if [[ "${LCARS_INSTALL_SKIP_GATE:-0}" == "1" ]]; then
      echo "install: ATTENTION — gate saute (LCARS_INSTALL_SKIP_GATE=1) : la release n'est PAS attestee par le gate de ce commit" >&2
    else
      echo "install: gate complet sur l'arbre source (compile-strict + tests + bats + topologie + dialyzer)…" >&2
      # SC2209 : `MIX_ENV="test"` avec les guillemets — sans eux, shellcheck lit `test` comme un
      # NOM DE COMMANDE et croit a un `MIX_ENV=$(test)` oublie. Le signalement est un faux positif,
      # la paire de guillemets le ferme sans rien changer d'autre.
      MIX_ENV="test" mix gate || exit 1
    fi

    MIX_ENV=prod mix release --overwrite || exit 1
  )
}

# ROOT IS REFUSED, and the reason is not caution -- it is that this script RUNS THE GATE, and the
# gate is not valid under root. Measured on a real run: `rm_terminal_artifacts` asserts `:eacces` on
# a chmod-000 directory, root bypasses permissions, `rm_rf` succeeds and the test reports a FAILURE
# that is an artifact of the runner, not of the code. A gate whose verdict depends on who invoked it
# attests nothing. Sudo also leaves the build tree littered with root-owned ExUnit artifacts (13167
# files under tmp/ on that run) which then break the next ordinary `mix compile` on File.touch!.
#
# The privileged half is the FILE PLACEMENT, not the build. Run this as the account that owns the
# install (or grant it write on the prefix); elevate only the copy, as etc/README.md's manual
# procedure does. Elevating the whole script is what conflates the two.
# ⚠ `$1` EST UN JOINT DE TEST, ET C'EST POURQUOI SC2120 EST DECLARE. `install.bats` appelle
# `refuse_root 0` et `refuse_root 1000` pour exercer les deux cotes sans etre root ni changer d'uid.
# La production n'en passe jamais : le defaut `${EUID}` est le cas reel. Un parametre qu'aucun
# appelant de production ne fournit est exactement ce que SC2120 signale — la decision est prise,
# elle se dit ici plutot que de laisser le signalement se faire ignorer chaque semaine.
# shellcheck disable=SC2120
refuse_root() {
  # `$1` is the WITNESS SEAM (both branches are exercised in test/etc/install.bats); the default
  # is `$EUID`, and it has no fallback of its own because bash sets EUID before the first line of
  # this file runs. The line read `${1:-${EUID:-$(id -u)}}` until 2026-08-27: the `$(id -u)` was
  # unreachable code, and the cost was not the fork nobody saved -- it was that the line ASSERTED
  # the effective uid can be missing, which the next reader copies into their own guard.
  local uid="${1:-$EUID}"
  [[ "$uid" -ne 0 ]] || die "lance en root — le gate n'est pas valide sous root (il outrepasse les permissions que des tests verifient) et le build laisserait des artefacts root dans l'arbre source. Lance-le sous le compte proprietaire de l'install ; seule la POSE demande des droits (cf. etc/README.md)"
}

# Fail on the prefix BEFORE spending several minutes on a gate + release. The old flow discovered the
# permission at the copy, i.e. after the expensive part, and died with a staging error that named the
# symptom rather than the cause.
require_prefix_writable() {
  local prefix="$1" probe="$1"
  while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || die "prefix non inscriptible : $probe (destination $prefix). Lance-le sous le compte proprietaire, ou donne-toi le droit d'ecriture — ne relance PAS en sudo, cf. refuse_root"
}

# PATH symlinks — POINTERS, not copies; the manifest's `link` entries. Extracted as a function so
# the VERDICT can be exercised without a three-minute `mix release`: the 6-110 defect lives in what
# this loop returns, never in the build. Reads the globals the main body has already set
# (`MF_FILES`, `MF_LINKS`, `PREFIX`, `LINK_DIR`); returns 1 as soon as one required link is missing.
wire_path_links() {
  local i f
  link_fail=0
  linked=""

  for i in "${!MF_FILES[@]}"; do
    [[ "${MF_LINKS[$i]}" -eq 1 ]] || continue
    f="${MF_FILES[$i]}"

    if ln -sf "$PREFIX/bin/$f" "$LINK_DIR/$f" 2>/dev/null; then
      linked="$linked $f"
    else
      link_fail=1
      say "symlink $LINK_DIR/$f KO (droits ?). Manuel : sudo ln -sf $PREFIX/bin/$f $LINK_DIR/"
    fi
  done

  [[ "$link_fail" -eq 0 ]] &&
    say "symlinks $LINK_DIR/{${linked# }} → $PREFIX/bin/ (entrees « link » du manifest)"

  return "$link_fail"
}

# Source guard (standard idiom): sourcing loads the functions WITHOUT running the deploy — the bats
# suite drives atomic_swap_dir / atomic_swap_file / wire_path_links directly, without a mix build.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

# ⚠ LITTERAL, ET IL LE RESTE. Ce script est AUTONOME — il s'installe sans le rail de
# provisionnement et ne source pas sa lib : il ne peut pas deriver de `PROV_ROOT`. L'accord des deux
# defauts est tenu par `deploy/tests/racine_prefixe.bats`, pas par un partage de variable.
PREFIX="${LCARS_INSTALL_PREFIX:-/opt/lcars/runtime}"

SELF="$(readlink -f "$0")"
ETC_DIR="$(dirname "$SELF")"
RUNTIME_DIR="$(dirname "$ETC_DIR")"          # etc/.. = the source runtime root
SRC_BIN="$RUNTIME_DIR/bin"

# --- 0. Config guards FIRST (fail on bad config before any environment check or build) ------------
# This script later runs `rm -rf $PREFIX/rel` and recursive chgrp/chmod on $PREFIX: a shallow
# prefix (`/`, `/usr`) would be a system-wide disaster (ring0-substrat finding). Absolute,
# depth >= 2, no exception.
RAW_PREFIX="$PREFIX"
PREFIX="${PREFIX%/}"
case "$PREFIX" in
  /?*/?*) : ;;
  *) die "LCARS_INSTALL_PREFIX doit etre absolu, profondeur >= 2 (recu : '$RAW_PREFIX')" ;;
esac

# The manifest is parsed and validated BEFORE the (long) build: a typo dies in milliseconds,
# not after three minutes of mix release. Unknown tokens are a build error, never a skip.
MANIFEST="$ETC_DIR/release.manifest"
[[ -f "$MANIFEST" ]] || die "manifest absent : $MANIFEST (checkout incomplet ?)"
declare -a MF_FILES=() MF_MODES=() MF_LINKS=()
while read -r mf_name mf_mode mf_flag mf_extra; do
  [[ -z "$mf_name" || "$mf_name" == \#* ]] && continue
  [[ -z "$mf_extra" ]] || die "manifest : token en trop « $mf_extra » sur l'entree « $mf_name »"
  case "$mf_mode" in
    exec|noexec) : ;;
    *) die "manifest : mode inconnu « ${mf_mode:-<vide>} » pour « $mf_name » (exec|noexec)" ;;
  esac
  mf_link=0
  if [[ -n "$mf_flag" ]]; then
    [[ "$mf_flag" == "link" ]] || die "manifest : flag inconnu « $mf_flag » pour « $mf_name » (seul : link)"
    mf_link=1
  fi
  MF_FILES+=("$mf_name"); MF_MODES+=("$mf_mode"); MF_LINKS+=("$mf_link")
done < "$MANIFEST"
[[ "${#MF_FILES[@]}" -gt 0 ]] || die "manifest vide : $MANIFEST"

[[ -f "$RUNTIME_DIR/mix.exs" ]] || die "pas la racine du runtime source ($RUNTIME_DIR/mix.exs absent)"
# ⚠ `mix` N'EST EXIGE QUE POUR CONSTRUIRE, ET CE SCRIPT NE CONSTRUIT PAS TOUJOURS. `build_release()`
# sait deja lire le discriminant — « paquet : release batie par pack.sh, ni gate ni compilation » —
# mais ce garde s'executait AVANT, et refusait donc la seule livraison qui n'a rien a compiler.
#
# MESURE DU 2026-09-01, banc 2006 : `install: ERREUR — mix introuvable`, sur une machine dont le
# paquet portait la release COMPLETE, prete a poser. Le script mourait dix lignes avant la fonction
# qui aurait dit « rien a batir ».
#
# ⚠ ET LE TAMPON EST LU ICI COMME AILLEURS, PAS DEDUIT. Ce script est autonome — il ne source pas la
# lib du rail, c'est ecrit plus bas — donc il refait le meme test que `prov_delivery` au lieu de
# l'appeler. Deux lecteurs, une seule convention : le fichier a la racine du paquet.
if [[ ! -f "$RUNTIME_DIR/../.source-revision" ]]; then
  command -v mix >/dev/null 2>&1 || die "mix introuvable (Elixir requis pour construire la release)"
fi

# Both guards BEFORE the build: a refusal must cost a second, not a full gate.
# shellcheck disable=SC2119  # sans argument = le defaut `$EUID` : c'est le cas de production.
refuse_root
require_prefix_writable "$PREFIX"

# --- 1. Build the prod release (self-contained, bundled ERTS), TIED to the full gate on the same
#        source tree (build_release: gate → release). A red gate or a failed build dies here.
say "build release prod (gate complet puis MIX_ENV=prod mix release)…"
build_release "$RUNTIME_DIR" || die "gate rouge ou build KO — la release n'est PAS posee (arbre source non atteste)"
REL_SRC="$RUNTIME_DIR/_build/prod/rel/lcars_fleet"
[[ -x "$REL_SRC/bin/lcars_fleet" ]] || die "release introuvable une fois le build fini ($REL_SRC)"

# --- 2. $PREFIX layout (idempotent) ----------------------------------------------------------------
say "pose sous $PREFIX…"
mkdir -p "$PREFIX/bin" "$PREFIX/etc" "$PREFIX/rel"

# The release lands under `$PREFIX/rel/lcars_fleet/` via a staged, verified, atomic swap — the live
# tree is never destroyed before the new one is proven good, and the previous stays as `.prev`.
atomic_swap_dir "$REL_SRC" "$PREFIX/rel/lcars_fleet" "bin/lcars_fleet"

# NON-BEAM files (outside the release): the manifest says WHAT ships and with which mode — this
# loop is blind to content. Per-file chmod, hard failure (the old blanket `chmod ... || true`
# could silently ship a non-executable launcher).
#
# The placement stays the ATOMIC SWAP, not a bare `cp`: a reader must never catch a half-written
# launcher, and `$PREFIX/bin` is read by a LIVE fleet (the human's BEAM resolves the pod launchers
# from there at every spawn). The manifest changed WHAT ships, not HOW it lands; a direct copy over
# a live file reopens a window this script had already closed. The chmod comes AFTER the swap, so
# the mode is asserted on the file that is actually in place.
#
# `fleet_mcp_stdio_bridge.py` is `noexec` by design and needs no execute bit: it is invoked as
# `python3 <path>` (config/runtime.exs mcp_server_spec) after pod.ex copies it per-pod. It DOES need
# to be readable by the human's BEAM — the group-read of step 3 provides that.
for i in "${!MF_FILES[@]}"; do
  f="${MF_FILES[$i]}"
  [[ -e "$SRC_BIN/$f" ]] || die "entree du manifest absente du source bin/ : $f"
  atomic_swap_file "$SRC_BIN/$f" "$PREFIX/bin/$f"
  if [[ "${MF_MODES[$i]}" == "exec" ]]; then
    chmod +x "$PREFIX/bin/$f" || die "chmod +x refuse : $PREFIX/bin/$f"
  fi
done

# Template d'env humain (swap atomique aussi — un lecteur ne voit jamais un template tronque).
atomic_swap_file "$RUNTIME_DIR/etc/fleet_v2.env.template" "$PREFIX/etc/fleet_v2.env.template"

# --- 3. Perms: RO for humans (group fleet r-x), owner = the installer (system) ----------------------
# The BEAM writes its tmp/state into ~/.lcars (RELEASE_TMP, set by fleet_v2), so the install stays RO.
#
# The mode is ADDITIVE + subtractive, and the additive half matters: `g-w,o-rwx` alone only REMOVES
# group-write and other-access. It never GRANTS group read or traverse — those were inherited from
# whatever the source tree happened to carry, so the announced "group fleet r-x" was true by accident of
# the repo's umask rather than by anything this script did. `g+rX` establishes it (capital X = execute
# on directories and on files that already carry an execute bit, so it does not make data executable).
# This is the same policy the manual procedure in etc/README.md applies with `chmod g+rx`.
#
# The message is only printed when the chmod ACTUALLY applied: a `|| true` used to hide a failed chmod
# behind a success line — an access policy announced but not applied.
if chgrp -R fleet "$PREFIX" 2>/dev/null; then
  if chmod -R g+rX,g-w,o-rwx "$PREFIX" 2>/dev/null; then
    say "perms : group fleet r-x, others none (RO humains)"
  else
    say "chmod perms KO — la politique RO (group r-x, others none) n'est PAS en place ; le deploy doit la poser"
  fi
else
  say "chgrp fleet KO (droits ?) — le deploy doit le poser"
fi

# --- 4. PATH symlinks (launch from anywhere) — POINTERS, not copies; `link` manifest entries ------
LINK_DIR="${LCARS_INSTALL_LINK_DIR:-/usr/local/bin}"
wire_path_links || true

# LE COMPTEUR ETAIT POSE ET JAMAIS LU. `link_fail=1` etait ecrit dans la boucle, puis le script
# annoncait `OK` inconditionnellement et rendait 0. Une install lancee sans droit sur `$LINK_DIR`
# se declarait donc en place alors que ses commandes PATH sont absentes — ou pire, pointent encore
# sur une version precedente : le `ln -sf` echoue, l'ancien lien survit, et l'operateur lance une
# release qu'il croit neuve.
#
# La release POSEE reste posee : elle est valide, c'est le cablage qui manque, et la detruire
# punirait un build de trois minutes pour un probleme de droits. Ce qui change est le VERDICT —
# code 3, distinct du 1 des echecs durs, et aucun message final « OK ».
if [[ "$link_fail" -ne 0 ]]; then
  say "INSTALL INCOMPLETE — la release est en place sous $PREFIX, mais au moins un symlink de"
  say "  $LINK_DIR n'a pas pu etre pose (voir les lignes « symlink … KO » ci-dessus)."
  say "  Les commandes PATH sont donc absentes, ou pointent encore sur une version PRECEDENTE."
  say "  Reparer les liens ci-dessus, ou relancer avec les droits sur $LINK_DIR."
  exit 3
fi

say "OK — install en place sous $PREFIX (release : $(cat "$PREFIX/rel/lcars_fleet/releases/start_erl.data" 2>/dev/null || echo '?'))."
say "Lancer : fleet_v2 start   (tout le per-humain vit en ~/.lcars/* ; le repo n'est PAS requis au runtime)."
