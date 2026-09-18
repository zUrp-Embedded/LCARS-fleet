#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/homonymes.bats
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: bats tests — les fonctions qui portent le meme nom des deux cotes sont DECLAREES, en deux familles

# RT-C-20. Dix-neuf fonctions portent le meme nom dans le protocole du produit et dans la lib de
# l'installeur. Ce n'etait pas un choix tenu, c'etait une copie qui a diverge — et sans ce mur,
# l'ensemble grossit d'un nom a chaque passe sans que personne ne le decide.
#
# DEUX FAMILLES, ET ELLES N'ONT PAS LE MEME STATUT. La note qui les explique vit dans
# `runtime/services/README.md` ; c'est ICI que leur composition fait foi.

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INSTALLER="$REPO/deploy/lib/provision-lib.sh"
  PRODUCT="$REPO/runtime/services/lib/module-protocol.sh"
  [ -f "$INSTALLER" ]
  [ -f "$PRODUCT" ]
}

# LE DIALECTE APPARTIENT AU RAIL, et ces homonymes sont voulus : le tag, les compteurs, la couleur
# (l'installeur parle a un terminal, le produit a un journal) et le piege de sortie. Les fondre
# donnerait a l'installeur le piege du produit, donc une autre sortie. L'accord de leurs VERDICTS
# est tenu a part, par `verdict_parity.bats`.
DIALECTE="p_step p_ok p_chg p_drift p_warn p_fail p_die verdict_apply verdict_check"

# AUCUNE IDENTITE DE RAIL : des primitives de fichier et de reseau. Mesure du 2026-09-19 : elles ne
# different que par le compteur qu'elles incrementent et la ponctuation de leurs phrases, et deux
# d'entre elles sont deja identiques au caractere pres. Cette liste est la DETTE ; elle RETRECIT.
COPIES="advertise_addr ensure_dir ensure_mode env_field lan_addr prov_owner prov_refuse_symlink_path read_token run_quiet write_atomic"

noms() { grep -oE '^[a-z_][a-z0-9_]*\(\)' "$1" | tr -d '()' | sort -u; }

homonymes() { comm -12 <(noms "$PRODUCT") <(noms "$INSTALLER"); }

declares() { printf '%s\n' $DIALECTE $COPIES | sort -u; }

@test "MUR: aucun homonyme qui ne soit declare — un nom de plus est une decision, pas un accident" {
  local inconnus
  inconnus="$(comm -23 <(homonymes) <(declares) | tr '\n' ' ')"
  [ -z "${inconnus// /}" ] || {
    echo "homonyme(s) NON declare(s) : $inconnus" >&2
    echo "→ range-le dans DIALECTE (le rail le possede) ou dans COPIES (dette a resorber)," >&2
    echo "  et dis pourquoi dans runtime/services/README.md. Un homonyme muet redevient une copie." >&2
    return 1
  }
}

@test "MUR: le dialecte d'un rail ne disparait pas en silence — les deux cotes le portent encore" {
  local perdus
  perdus="$(comm -23 <(printf '%s\n' $DIALECTE | sort -u) <(homonymes) | tr '\n' ' ')"
  [ -z "${perdus// /}" ] || {
    echo "du DIALECTE, un cote ne porte plus : $perdus" >&2
    echo "→ le protocole des deux rails a cesse de se repondre : c'est un changement de contrat." >&2
    return 1
  }
}

@test "la dette est EXACTE : une copie resorbee sort de la liste, sinon elle pourrit" {
  local fantomes
  fantomes="$(comm -23 <(printf '%s\n' $COPIES | sort -u) <(homonymes) | tr '\n' ' ')"
  [ -z "${fantomes// /}" ] || {
    echo "COPIES nomme ce qui n'est plus un homonyme : $fantomes" >&2
    echo "→ resorbee ? retire-la de COPIES. Une dette qu'on ne solde pas dans la liste se rachete" >&2
    echo "  deux fois : la prochaine passe la cherche encore." >&2
    return 1
  }
}

# ⚠ LA POPULATION FAIT PARTIE DU CONTRAT. Sans cette mesure, un fichier vide ou une forme de
# definition que `noms` ne reconnait plus rendrait les trois tests ci-dessus verts SANS RIEN LIRE.
@test "population: les deux libs se lisent, et l'ensemble mesure n'est pas vide" {
  [ "$(noms "$PRODUCT" | wc -l)" -gt 10 ]
  [ "$(noms "$INSTALLER" | wc -l)" -gt 10 ]
  [ "$(homonymes | wc -l)" -gt 0 ]
}
