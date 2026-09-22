#!/usr/bin/env bash
# SOURCE: runtime/services/lib/uid-bounds.sh
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: actif — LA FRONTIERE SYSTEME/HUMAIN : l'unique lecture shell de `login.defs`
#
# ⚖ Phase 5 du plan runtime : « la regle des bornes d'uid ecrite une fois par langage ». Elle
# l'etait TROIS fois cote produit — le protocole des humains, la console, le lanceur —, et le
# commentaire du protocole disait pourquoi : « leur hote ne peut pas sourcer un protocole de
# module ». C'est ce « ne peut pas » qui tombe : ce fichier-ci ne porte QUE la lecture, il
# n'imprime rien et ne depend de rien. N'importe quel script du produit peut le sourcer.
#
# ⚠ SOURCE, JAMAIS EXECUTE. Aucun `set -e` ici : l'appelant a deja pose le sien.
#
# ⚠ AUCUN REPLI SUR 1000 NI SUR 60000, ET C'EST TOUT L'OBJET. Un `login.defs` illisible ne veut pas
# dire « la frontiere est a 1000 », il veut dire « la frontiere n'est pas etablie ». Un UID_MIN reel
# a 2000 devine a 1000 ferait humain tout ce qui vit entre les deux — et un UID_MAX devine ferait
# humain `nobody` (65534, sur toute machine). Le mur I18 tient ce vide des deux cotes.
#
# ⚠ LA BORNE NE SE LIT PAS DANS L'ENVIRONNEMENT DU PROCESSUS GARDE (`UID_MIN=0 …`) : « la frontiere
# obeirait a qui la franchit » (runtime.exs). `UID_MIN` et `UID_MAX` sont RE-ECRITS a chaque appel
# depuis le fichier — une valeur heritee de l'environnement n'y survit pas. Seul le CHEMIN se
# regle (`PASSWD_DEFS`), et c'est ce que font les temoins.
#
# ⚠ CE FICHIER N'IMPRIME RIEN, et c'est ce qui le rend sourcable partout. Ne pas avoir pu lire la
# borne se DIT differemment selon l'hote : le protocole en fait un `p_warn` dit une fois, la
# console rend une liste vide, le lanceur refuse de lancer. Chacun garde son mot ; la cause, elle,
# est ecrite une fois, dans `UID_BOUNDS_WHY`.
#
# ⚠ LE NOM EST `uid_bounds_read`, PAS `uid_bounds`. Le protocole des humains ENVELOPPE cette
# lecture pour la dire une fois dans son dialecte ; une enveloppe qui porterait le meme nom
# s'appellerait elle-meme — bash resout les fonctions A L'APPEL, pas a la definition, et la
# recursion serait infinie.
#
# `$1 == "UID_MIN"` et PAS `/^UID_MIN/` : le second matche aussi une clef dont `UID_MIN` n'est que
# le prefixe. Trois lecteurs sur quatre avaient deja la forme stricte ; la console avait l'autre.

# ⚠ `UID_BOUNDS_FILE` EST PUBLIQUE, ET CE N'EST PAS DU CONFORT : un appelant qui nommerait le
# fichier dans son refus le recalculerait — donc recopierait `${PASSWD_DEFS:-/etc/login.defs}`, et
# un jour les deux designeraient deux fichiers. Le chemin RETENU se lit ici.
# shellcheck disable=SC2034  # les quatre se lisent chez l'APPELANT : c'est tout l'objet de ce fichier
UID_MIN="" UID_MAX="" UID_BOUNDS_WHY="" UID_BOUNDS_FILE=""

uid_bounds_read() { # 0 si les deux bornes se lisent (UID_MIN/UID_MAX posees) ; 1 sinon, cause dans UID_BOUNDS_WHY
  local defs="${PASSWD_DEFS:-/etc/login.defs}" manque=""
  UID_BOUNDS_FILE="$defs"
  UID_MIN="$(awk '$1 == "UID_MIN" {print $2; exit}' "$defs" 2>/dev/null || true)"
  UID_MAX="$(awk '$1 == "UID_MAX" {print $2; exit}' "$defs" 2>/dev/null || true)"
  [[ "$UID_MIN" =~ ^[0-9]+$ ]] || manque=UID_MIN
  [[ -n "$manque" || "$UID_MAX" =~ ^[0-9]+$ ]] || manque=UID_MAX
  if [[ -z "$manque" ]]; then UID_BOUNDS_WHY=""; return 0; fi
  # ⚠ VIDEES, PAS LAISSEES A MOITIE : un appelant qui ignorerait le code de retour comparerait un
  # uid a une borne vide, ce que bash lit comme 0 — et tout deviendrait humain.
  UID_MIN="" UID_MAX=""
  UID_BOUNDS_WHY="la frontiere systeme/humain n'est pas etablie ($manque illisible dans $defs) — la borne est declaree par le systeme, pas par ce processus : repare $defs"
  return 1
}
