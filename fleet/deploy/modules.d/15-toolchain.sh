#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/15-toolchain.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — toolchain de BUILD : Erlang/OTP (apt, plancher) + Elixir précompilé PINNÉ (sha256)
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# (CHECK-ON sans docker — délibéré, et ce n'est PAS le « 10/15 CHECK-ON » du plan ADR §11 pris au
# mot : la toolchain vit dans le STAGE BUILD de l'image, pas dans le conteneur runtime. L'état-cible
# « toolchain posée » n'a pas à être vrai là où on ne buildera jamais ; la vérité docker de ce
# module, c'est la release présente — sondée par 60-deploy check.)
#
# La release lcars_fleet est self-contained (ERTS bundlé) : la toolchain ne sert qu'à BÂTIR
# (etc/install.sh → mix release), jamais au run. En Docker, elle vit dans le stage builder de
# l'image (même pin), absente du stage runtime — d'où SUBSTRATE: wsl linux.
#
# Deux horloges distinctes, deux mécanismes (délibéré) :
#   - Erlang/OTP : apt distro, contrainte PLANCHER (>= PROV_ELIXIR_OTP_MAJOR). L'apt Ubuntu 26.04
#     livre `erlang-base 1:27.3.4.6+dfsg-1` = exactement ce que le runtime déployé bundle. Pas de
#     pin exact sur apt (on ne fige pas ce qu'on ne contrôle pas — le gate CI verrouille la compat
#     réelle).
#     ⚠ UN PLANCHER NE DIT RIEN DE L'ÉCART AU-DESSUS DE LUI, et le même cran choisit la variante du
#     zip Elixir. Le 2026-08-22, un hôte 26.04 a servi OTP 27 sous un plancher 25 : vert, et Elixir
#     posé en variante OTP 25 par-dessus. Si le plancher redescend un jour sous ce que sert la
#     distro, l'écart revient — en silence, parce que c'est la définition d'un plancher.
#   - Elixir : l'apt distro est PRÉHISTORIQUE (1.14 sur noble, plancher requis ~1.18) → précompilé
#     officiel elixir-lang, zip PINNÉ version+sha256 (fetch_verify), posé sous /opt/elixir-<ver>
#     + symlinks /usr/local/bin. Bump = changer LA paire (PROV_ELIXIR_VERSION, PROV_ELIXIR_ZIP_SHA256)
#     dans lib/provision-lib.sh ; le mismatch sha te copie-colle le hash réel dans son message.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

ELIXIR_HOME="/opt/elixir-${PROV_ELIXIR_VERSION}"
ELIXIR_URL="https://github.com/elixir-lang/elixir/releases/download/v${PROV_ELIXIR_VERSION}/elixir-otp-${PROV_ELIXIR_OTP_MAJOR}.zip"
ELIXIR_BINS=(elixir elixirc mix iex)

otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0; }
elixir_version() { /usr/local/bin/elixir --short-version 2>/dev/null || echo absent; }

# La VARIANTE de build du precompile, pas la version : `elixir --version` dit « Elixir 1.18.4
# (compiled with Erlang/OTP 25) ». `--short-version` jette cette moitie-la, et c'est la moitie qui
# a manque le 2026-08-22 — un poste en OTP 27 portant la variante OTP 25, sonde au VERT parce que
# « 1.18.4 » == « 1.18.4 ». Une sonde aveugle a la seule chose qui derive ne sonde rien.
elixir_built_for() {
  /usr/local/bin/elixir --version 2>/dev/null \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p' | head -1
}

check() {
  # Erlang plancher.
  if command -v erl >/dev/null; then
    local otp; otp="$(otp_release)"
    if [[ "$otp" -ge "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Erlang/OTP $otp (plancher $PROV_ELIXIR_OTP_MAJOR)"
    else
      p_drift "Erlang/OTP $otp < plancher $PROV_ELIXIR_OTP_MAJOR"
    fi
  else
    p_drift "erl absent (paquet apt erlang)"
  fi

  # Elixir pin exact — VERSION et VARIANTE, parce que la seconde est celle qui a derive.
  local ev; ev="$(elixir_version)"
  if [[ "$ev" != "$PROV_ELIXIR_VERSION" ]]; then
    p_drift "Elixir « $ev » ≠ pin $PROV_ELIXIR_VERSION (attendu : $ELIXIR_HOME + symlinks /usr/local/bin)"
  else
    local built; built="$(elixir_built_for)"
    if [[ "$built" == "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Elixir $ev, variante OTP $built (= pin)"
    elif [[ -z "$built" ]]; then
      p_drift "Elixir $ev : variante de build illisible (« elixir --version » n'annonce plus son OTP ?)"
    else
      p_drift "Elixir $ev compile pour OTP $built, pin OTP $PROV_ELIXIR_OTP_MAJOR — le mauvais zip est pose"
    fi
  fi
  verdict_check
}

apply() {
  # 1. Erlang via apt (le méta-paquet tire toutes les applications OTP dont mix release a besoin).
  if [[ "$(otp_release)" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    apt_ensure erlang || verdict_apply
    local otp; otp="$(otp_release)"
    if [[ "$otp" -ge "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Erlang/OTP $otp"
    else
      p_fail "Erlang/OTP « $otp » toujours sous le plancher $PROV_ELIXIR_OTP_MAJOR après apt (distro trop vieille ?)"
      verdict_apply
    fi
  fi

  # 2. Elixir précompilé pinné. Dépose côte-à-côte versionnée (/opt/elixir-<ver>) : l'ancienne
  #    version reste intacte jusqu'au basculement des symlinks — un download raté ne casse RIEN
  #    (la v1 faisait `rm` du binaire AVANT le download : échec réseau = plus d'outil du tout).
  #    La VARIANTE compte autant que la version : un poste qui porte deja 1.18.4 mais compile pour
  #    un autre OTP ne serait jamais repose si on ne comparait que le numero.
  if [[ "$(elixir_version)" != "$PROV_ELIXIR_VERSION" || "$(elixir_built_for)" != "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    local zip="/opt/.elixir-${PROV_ELIXIR_VERSION}.zip"
    ensure_dir /opt 0755 root:root || verdict_apply
    fetch_verify "$ELIXIR_URL" "$PROV_ELIXIR_ZIP_SHA256" "$zip" 0644 || verdict_apply
    # Dépose dans un dossier de travail puis mv (le zip vérifié peut quand même être ré-extrait
    # après un crash : le .partial est jetable, le mv final est atomique).
    rm -rf "${ELIXIR_HOME}.partial"
    p_step "Elixir $PROV_ELIXIR_VERSION (OTP $PROV_ELIXIR_OTP_MAJOR) — decompression du precompile officiel"
    if ! run_quiet unzip -q "$zip" -d "${ELIXIR_HOME}.partial"; then
      rm -rf "${ELIXIR_HOME}.partial" "$zip"; p_fail "unzip du précompilé Elixir"; verdict_apply
    fi
    rm -rf "$ELIXIR_HOME"
    mv "${ELIXIR_HOME}.partial" "$ELIXIR_HOME"
    rm -f "$zip"
    local b
    for b in "${ELIXIR_BINS[@]}"; do
      ensure_symlink "/usr/local/bin/$b" "$ELIXIR_HOME/bin/$b" || verdict_apply
    done
    # Verdict réel : la version ET la variante qui répondent SONT le pin.
    local ev built; ev="$(elixir_version)"; built="$(elixir_built_for)"
    if [[ "$ev" != "$PROV_ELIXIR_VERSION" ]]; then
      p_fail "Elixir répond « $ev » après pose ≠ pin $PROV_ELIXIR_VERSION (PATH parasite ? apt elixir devant /usr/local ?)"
    elif [[ "$built" != "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_fail "Elixir $ev posé mais compilé pour OTP ${built:-?} ≠ pin OTP $PROV_ELIXIR_OTP_MAJOR (zip de la mauvaise variante, ou binaire d'ailleurs devant /usr/local)"
    else
      p_chg "Elixir $ev (OTP $built) posé ($ELIXIR_HOME)"
    fi
  fi
  verdict_apply
}

case "${1:?usage: 15-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
