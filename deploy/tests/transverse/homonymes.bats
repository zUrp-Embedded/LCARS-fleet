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
#
# ⚖ `_compte_pose` EST UN HOMONYME NEUF, ET VOULU (phase 6) : c'est le crochet par lequel les
# primitives partagees comptent une pose sans savoir dans quel rail elles tournent — le produit
# incremente `LCARS_CHANGED`, l'installeur `PROV_CHANGED`. Un compteur PARTAGE ferait lire a un
# rail le travail de l'autre ; deux corps d'une ligne, chacun chez soi, est la bonne forme.
DIALECTE="p_step p_ok p_chg p_drift p_warn p_fail p_die verdict_apply verdict_check _compte_pose"

# AUCUNE IDENTITE DE RAIL : des primitives de fichier et de reseau. Cette liste est la DETTE ; elle
# RETRECIT.
#
# ⚖ PHASE 6, PREMIERE MOITIE SOLDEE (2026-09-19). `env_field`, `read_token`, `ensure_dir`,
# `ensure_mode` et `write_atomic` vivent dans `runtime/services/lib/primitives.sh`, que les DEUX
# libs sourcent — le sens deja permis, l'installeur appelant le produit. Elles ne sont plus des
# homonymes : il n'y a plus qu'un corps. Et ce n'etait pas qu'une redondance — `ensure_mode` du
# produit RELISAIT le mode apres `chmod`, celui de l'installeur non.
#
# ⚖ PHASE 6, ETAPE 2 (2026-09-20). `prov_refuse_symlink_path` sort de cette liste : il vit dans
# `primitives.sh`, comme les cinq de l'etape 1. Il y etait declare « son refus porte le vocabulaire
# du decor » — et la mesure dit le contraire. Les deux corps etaient IDENTIQUES, ligne pour ligne, a
# la ponctuation du message pres ; aucun ne portait le moindre vocabulaire de decor. La
# justification etait fausse, et c'est elle qui gardait vingt lignes ecrites deux fois hors de la
# dette. ⚠ UNE LIGNE DE CETTE LISTE EST UNE DECISION QUI SE RELIT : une justification qu'on n'a pas
# remesuree depuis qu'elle a ete ecrite n'est plus une justification, c'est une habitude.
#
# ⚠ DEUXIEME JUSTIFICATION FAUSSE DE LA MEME LISTE, MEME JOUR. `lan_addr` sort aussi : ses deux
# corps etaient identiques OCTET POUR OCTET. Sa ligne disait « advertise_addr, lan_addr — l'installeur
# connait l'adresse que l'operateur a choisie » : c'est vrai d'`advertise_addr`, qui sait WSL et son
# mode NAT, et FAUX de `lan_addr`, qui ne sait rien de l'operateur et demande au noyau quelle source
# il mettrait sur un paquet sortant. Une justification VOISINE, heritee par la virgule.
#
# CE QUI RESTE PORTE UNE IDENTITE DE RAIL, et chacune a ete REMESUREE le 2026-09-20 :
#   advertise_addr   l'installeur a une branche WSL/NAT que le produit n'a pas, et le produit
#                    honore un `LCARS_ADVERTISE` deja pose que l'installeur recalcule ;
#   prov_owner       sa clause de DECOR — une ligne, qui lit `LCARS_DECOR_ROOT` ;
#   run_quiet        l'installeur CAPTURE et dumpe (`run_capture`, `prov_dump_last`), le produit
#                    imprime et rend 1.
COPIES="advertise_addr prov_owner run_quiet"

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
