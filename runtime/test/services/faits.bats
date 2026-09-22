#!/usr/bin/env bats
# SOURCE: runtime/test/services/faits.bats
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: bats tests — `services/lib/facts.sh`, l'unique lecteur shell des FAITS DE LA MACHINE
#
# ⚖ Decision 3 du plan runtime. Un fait — le groupe `fleet`, l'org systeme, le repertoire des
# jetons — s'ecrit UNE fois dans `etc/facts.env` et quatre langages le lisent. Ce temoin tient les
# trois proprietes qui font que les quatre rails disent la meme chose :
#
#   · L'ORDRE. L'environnement gagne sur le fichier. Ce que l'installeur transporte par
#     `services.env`, ou ce qu'un operateur pose a la main, PRIME — sinon un poste provisionne
#     lirait le defaut du produit au lieu de son propre reglage.
#   · LE REFUS. Un fichier illisible est une MORT, pas un dictionnaire vide. Sans ce garde, un
#     geste tournerait avec `LCARS_PRIVATE_DIR=""` et irait ecrire a la racine.
#   · LA PORTEE. Le protocole des modules ne lit plus les faits lui-meme : il source CE fichier.
#     Deux implementations shell divergeraient, et c'est exactement ce qu'on vient de supprimer.

setup() {
  RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FAITS_SH="$RACINE/services/lib/facts.sh"
  PROTOCOLE="$RACINE/services/lib/module-protocol.sh"
  [ -f "$FAITS_SH" ]
  [ -f "$PROTOCOLE" ]
  DECOR="$BATS_TEST_TMPDIR/facts.env"
  printf 'LCARS_FLEET_GROUP=flotte\nLCARS_PRIVATE_DIR=/ailleurs/jetons\n' > "$DECOR"
  unset LCARS_FLEET_GROUP LCARS_PRIVATE_DIR LCARS_FACTS_FILE
}

lit() { # lit <fichier de faits> <expression apres le source>
  LCARS_FACTS_FILE="$1" bash -c "set -euo pipefail; . '$FAITS_SH'; $2"
}

@test "un fait se lit depuis le fichier" {
  run lit "$DECOR" 'printf "%s|%s" "$LCARS_FLEET_GROUP" "$LCARS_PRIVATE_DIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "flotte|/ailleurs/jetons" ]
}

@test "L'ENVIRONNEMENT GAGNE : une valeur posee par l'appelant n'est pas ecrasee" {
  run env LCARS_FLEET_GROUP=equipage LCARS_FACTS_FILE="$DECOR" \
    bash -c "set -euo pipefail; . '$FAITS_SH'; printf '%s' \"\$LCARS_FLEET_GROUP\""
  [ "$status" -eq 0 ]
  [ "$output" = "equipage" ]
}

@test "un fichier illisible TUE, et le message nomme le fichier cherche" {
  run lit "$BATS_TEST_TMPDIR/absent.env" 'printf ok'
  [ "$status" -eq 1 ]
  [[ "$output" == *FATAL* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/absent.env"* ]]
  [[ "$output" != *ok* ]]
}

@test "ce qui n'est pas un fait n'entre pas : commentaires, lignes vides, noms hors LCARS_" {
  printf '# commentaire\n\nPATH=/nimporte/ou\nLCARS_FLEET_GROUP=flotte\npas_un_fait\n' > "$DECOR"

  run lit "$DECOR" 'printf "%s" "$LCARS_FLEET_GROUP"; [[ "$PATH" != /nimporte/ou ]] || printf " PATH-ECRASE"'
  [ "$status" -eq 0 ]
  [ "$output" = "flotte" ]
}

@test "les faits sont EXPORTES : un geste lance en fils les voit" {
  run lit "$DECOR" 'bash -c "printf %s \"\$LCARS_PRIVATE_DIR\""'
  [ "$status" -eq 0 ]
  [ "$output" = "/ailleurs/jetons" ]
}

@test "le protocole des modules N'A PLUS de lecteur a lui : il source celui-ci" {
  # Le protocole DERIVE (`LCARS_SYSTEM_GROUP` du compte systeme, `LCARS_OPS_REPO` de l'org) : sous
  # `set -u`, un decor incomplet le tue — et c'est le comportement voulu, pas un defaut du temoin.
  printf 'LCARS_FLEET_GROUP=flotte\nLCARS_PRIVATE_DIR=/ailleurs/jetons\nLCARS_SYSTEM_USER=sys\nLCARS_SYSTEM_ACCOUNT=capitaine\nLCARS_FORGE_ORG=flottille\n' > "$DECOR"

  run bash -c "set -euo pipefail; LCARS_MODULE_TAG=temoin LCARS_FACTS_FILE='$DECOR' . '$PROTOCOLE'; printf '%s' \"\$LCARS_FLEET_GROUP\""
  [ "$status" -eq 0 ]
  [ "$output" = "flotte" ]
  # aucune valeur de fait n'est ecrite dans le protocole : il n'en reste qu'un `source`
  # (`grep -c` rend 1 quand il ne compte rien : le compte est la mesure, pas son code de sortie)
  run bash -c "grep -cE '^\\s*:\\s*\"\\\$\\{LCARS_(FLEET_GROUP|PRIVATE_DIR|FORGE_ORG|SYSTEM_ACCOUNT|AUTHORITY_USER):=' '$PROTOCOLE' || true"
  [ "$output" = "0" ]
}

@test "ce qui se DERIVE d'un fait se derive chez le lecteur, et suit le fait" {
  printf 'LCARS_FORGE_ORG=flottille\nLCARS_PRIVATE_DIR=/ailleurs/jetons\nLCARS_SYSTEM_ACCOUNT=capitaine\nLCARS_SYSTEM_USER=sys\n' > "$DECOR"

  run bash -c "set -euo pipefail; LCARS_MODULE_TAG=temoin LCARS_FACTS_FILE='$DECOR' . '$PROTOCOLE'; printf '%s|%s' \"\$LCARS_OPS_REPO\" \"\$LCARS_SYSTEM_TOKEN_FILE\""
  [ "$status" -eq 0 ]
  [ "$output" = "flottille/_ops|/ailleurs/jetons/capitaine.gitea_token" ]
}

# ─── CE QUE LA RELECTURE HOSTILE DU 2026-09-19 A MESURE ─────────────────────────────────────────

@test "une CLE MALFORMEE ne tronque plus la lecture : les faits SUIVANTS arrivent" {
  # `${!_cle:-}` sur « LCARS_A B » n'est pas ignore par bash : c'est une erreur, et la boucle
  # s'arretait la. Tout ce qui suivait la ligne fautive restait VIDE, sans un mot.
  printf 'LCARS_A B=x\nLCARS_FLEET_GROUP=flotte\n' > "$DECOR"
  run lit "$DECOR" 'printf "%s" "${LCARS_FLEET_GROUP:-VIDE}"'
  [ "$status" -eq 0 ]
  [ "$output" = "flotte" ]
}

@test "cle repetee : la DERNIERE gagne, comme chez les trois autres lecteurs" {
  printf 'LCARS_FLEET_GROUP=premier\nLCARS_FLEET_GROUP=dernier\n' > "$DECOR"
  run lit "$DECOR" 'printf "%s" "$LCARS_FLEET_GROUP"'
  [ "$status" -eq 0 ]
  [ "$output" = "dernier" ]
}

@test "cle repetee : l'environnement gagne quand meme, sur TOUTES les occurrences" {
  printf 'LCARS_FLEET_GROUP=premier\nLCARS_FLEET_GROUP=dernier\n' > "$DECOR"
  run env LCARS_FLEET_GROUP=pose_par_l_appelant \
    bash -c "set -euo pipefail; LCARS_FACTS_FILE='$DECOR'; . '$FAITS_SH'; printf '%s' \"\$LCARS_FLEET_GROUP\""
  [ "$status" -eq 0 ]
  [ "$output" = "pose_par_l_appelant" ]
}

@test "une derniere ligne SANS saut de ligne est un fait, pas un oubli" {
  printf 'LCARS_FLEET_GROUP=flotte\nLCARS_PRIVATE_DIR=/sans/saut' > "$DECOR"
  run lit "$DECOR" 'printf "%s" "${LCARS_PRIVATE_DIR:-VIDE}"'
  [ "$status" -eq 0 ]
  [ "$output" = "/sans/saut" ]
}
