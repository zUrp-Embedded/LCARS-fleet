#!/usr/bin/env bats
# bats file_tags=unit
# SOURCE: deploy/tests/transverse/advertise_parity.bats
# AUTHOR: bob
# STARDATE: 2026-09-20
# STATUS: bats tests — `advertise_addr` garde DEUX corps ; ce temoin tient l'accord de leur noyau
#
# ⚖ PHASE 6, ETAPE 2. `advertise_addr` reste dans la liste des copies de `homonymes.bats`, et pour
# une raison REMESUREE : l'installeur detecte le substrat et traite WSL en mode NAT (l'adresse de la
# VM n'est routee depuis aucune autre machine et change a chaque redemarrage), ce que le produit ne
# sait pas ; et le produit honore un `LCARS_ADVERTISE` deja pose, que l'installeur recalcule. Fondre
# les deux demanderait un crochet de substrat et un nom de variable passe en argument — une surface
# de crochet aussi grosse que la duplication qu'elle retirerait.
#
# MAIS LEUR NOYAU EST COMMUN, ET UN NOYAU COMMUN DERIVE. Trois regles vivent en double : la liste des
# binds JOKERS (`0.0.0.0`, `::`, `*`), le fait qu'un bind NOMME gagne tel quel, et le repli sur
# `127.0.0.1` quand la machine n'a pas d'adresse de sortie — avec la phrase qui le DIT, parce qu'un
# operateur qui recoit des liens en loopback doit savoir pourquoi.
#
# C'est le meme geste que `verdict_parity.bats` : on tient l'ACCORD de deux dialectes sans les
# fusionner. Ce temoin ne compare PAS ce qui est declare different — la branche WSL de l'installeur
# et l'honneur d'un `LCARS_ADVERTISE` pose par le produit ont chacun leur cas plus bas, qui les
# epingle comme des differences VOULUES.

load ../refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INSTALLER="$REPO/deploy/lib/provision-lib.sh"
  PRODUCT="$REPO/runtime/services/lib/module-protocol.sh"
  [ -f "$INSTALLER" ]
  [ -f "$PRODUCT" ]
}

# `lan_addr` est REMPLACEE apres le source : la mesure ne doit pas dependre du reseau de la machine
# qui joue le banc. `PROV_SUBSTRATE=linux` ecarte la branche WSL, qui est la difference DECLAREE.
adv_installeur() { # adv_installeur <bind> <ce que lan_addr rend> → « <adresse>|<pourquoi> »
  bash -c "set +e; . '$INSTALLER' >/dev/null 2>&1
    PROV_SUBSTRATE=linux
    lan_addr() { [ -z '$2' ] || printf '%s' '$2'; }
    advertise_addr '$1' >/dev/null 2>&1
    printf '%s|%s' \"\$PROV_ADVERTISE\" \"\$PROV_ADVERTISE_WHY\"" 2>/dev/null
}

adv_produit() { # adv_produit <bind> <ce que lan_addr rend> → « <adresse>|<pourquoi> »
  bash -c "set +e; . '$PRODUCT' >/dev/null 2>&1
    unset LCARS_ADVERTISE LCARS_ADVERTISE_WHY
    lan_addr() { [ -z '$2' ] || printf '%s' '$2'; }
    advertise_addr '$1' >/dev/null 2>&1
    printf '%s|%s' \"\$LCARS_ADVERTISE\" \"\$LCARS_ADVERTISE_WHY\"" 2>/dev/null
}

@test "PARITE : un bind NOMME gagne tel quel, des deux cotes, et ne porte aucune explication" {
  local b i p
  for b in 192.168.1.10 10.0.0.7 lcars.local; do
    i="$(adv_installeur "$b" 10.1.2.3)"; p="$(adv_produit "$b" 10.1.2.3)"
    [ "$i" = "$p" ] || { echo "bind=$b : installeur=«$i» produit=«$p»" >&2; return 1; }
    [ "$i" = "$b|" ] || { echo "bind=$b : attendu «$b|», obtenu «$i»" >&2; return 1; }
  done
}

@test "PARITE : les TROIS jokers passent la main a l'adresse de sortie, des deux cotes" {
  # Un joker de moins d'un cote, et ce rail annoncerait « 0.0.0.0 » dans ses liens OAuth.
  local b i p
  for b in 0.0.0.0 :: '*'; do
    i="$(adv_installeur "$b" 10.1.2.3)"; p="$(adv_produit "$b" 10.1.2.3)"
    [ "$i" = "$p" ] || { echo "joker=$b : installeur=«$i» produit=«$p»" >&2; return 1; }
    [ "$i" = "10.1.2.3|" ] || { echo "joker=$b : attendu «10.1.2.3|», obtenu «$i»" >&2; return 1; }
  done
}

@test "PARITE : sans adresse de sortie, les deux replient sur 127.0.0.1 ET LE DISENT" {
  # Le repli seul ne suffit pas : un operateur qui recoit des liens en loopback doit lire pourquoi.
  local i p
  i="$(adv_installeur 0.0.0.0 '')"; p="$(adv_produit 0.0.0.0 '')"
  [ "$i" = "$p" ] || { echo "sans route : installeur=«$i» produit=«$p»" >&2; return 1; }
  [[ "$i" == 127.0.0.1\|* ]] || { echo "attendu un repli sur 127.0.0.1, obtenu «$i»" >&2; return 1; }
  [[ "$i" == *"aucune adresse de sortie"* ]] || { echo "le repli ne dit pas pourquoi : «$i»" >&2; return 1; }
}

# ─── LES DEUX DIFFERENCES VOULUES, EPINGLEES COMME TELLES ───────────────────────────────────────

@test "DIFFERENCE VOULUE : le produit honore un LCARS_ADVERTISE deja pose, l'installeur recalcule" {
  # L'appelant qui en sait plus — l'installeur, qui connait WSL — la POSE avant d'appeler le produit.
  # Si le produit se mettait a recalculer, ce transport ne servirait plus a rien.
  local p
  p="$(bash -c "set +e; . '$PRODUCT' >/dev/null 2>&1
    LCARS_ADVERTISE=deja.pose
    lan_addr() { printf '%s' 10.1.2.3; }
    advertise_addr 0.0.0.0 >/dev/null 2>&1
    printf '%s' \"\$LCARS_ADVERTISE\"" 2>/dev/null)"
  [ "$p" = "deja.pose" ] || { echo "le produit a recalcule par-dessus un LCARS_ADVERTISE pose : «$p»" >&2; return 1; }
}

@test "DIFFERENCE VOULUE : WSL en mode NAT n'existe QUE cote installeur, et il l'explique" {
  local i
  i="$(bash -c "set +e; . '$INSTALLER' >/dev/null 2>&1
    PROV_SUBSTRATE=wsl
    wsl_networking_mode() { printf '%s' nat; }
    lan_addr() { printf '%s' 10.1.2.3; }
    advertise_addr 0.0.0.0 >/dev/null 2>&1
    printf '%s|%s' \"\$PROV_ADVERTISE\" \"\$PROV_ADVERTISE_WHY\"" 2>/dev/null)"
  [[ "$i" == localhost\|* ]] || { echo "WSL/NAT n'annonce plus localhost : «$i»" >&2; return 1; }
  [[ "$i" == *"NAT"* ]] || { echo "le choix WSL ne s'explique plus : «$i»" >&2; return 1; }

  # Et le produit n'a PAS cette branche : c'est ce qui justifie les deux corps.
  refute grep -q 'wsl_networking_mode' "$PRODUCT"
}
