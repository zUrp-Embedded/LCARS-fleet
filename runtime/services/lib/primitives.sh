#!/usr/bin/env bash
# SOURCE: runtime/services/lib/primitives.sh
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: actif — LES PRIMITIVES CONVERGENTES, une source pour les DEUX rails
#
# ⚖ Phase 6 du plan runtime (RT-C-20). Dix-neuf fonctions portaient le meme nom dans le protocole
# du produit et dans la lib de l'installeur ; `deploy/tests/transverse/homonymes.bats` les declare
# en deux familles. Ce fichier resorbe la seconde : les primitives SANS identite de rail, celles
# qui ne differaient que par le compteur qu'elles incrementent et la ponctuation de leurs phrases.
#
# ⚠ CE N'ETAIT PAS QU'UNE REDONDANCE, ET LA MESURE LE DIT. Au 2026-09-19, `ensure_mode` du PRODUIT
# relisait le mode apres `chmod` et refusait s'il n'avait pas pris ; celui de l'INSTALLEUR ne le
# faisait pas. Un `chmod` qui n'aboutit pas — un montage qui l'ignore, un systeme de fichiers sans
# permissions — etait compte comme pose sur un rail et refuse sur l'autre. Deux copies ne derivent
# pas seulement en prose : elles perdent des gardes, et celle-ci etait invisible.
#
# ⚠ SOURCE, JAMAIS EXECUTE. Aucun `set -e` ici : l'appelant a deja pose le sien.
#
# ─── CE QUE CE FICHIER ATTEND DE SON HOTE ───────────────────────────────────────────────────────
#
# Rien d'autre que le VOCABULAIRE du rail, et c'est ce qui rend le partage possible : bash resout
# les fonctions A L'APPEL, donc chaque rail fournit les siennes et ces primitives parlent sa langue.
#
#   · `p_fail`, `p_chg`      — le dialecte du rail (l'installeur parle a un terminal, le produit a
#                              un journal) ; leur accord de verdict est tenu par `verdict_parity` ;
#   · `_compte_pose`         — « un objet a ete pose » : le produit incremente `LCARS_CHANGED`,
#                              l'installeur `PROV_CHANGED`. Un compteur PARTAGE ferait qu'un rail
#                              lise le travail de l'autre ;
#   · `prov_owner`           — le proprietaire a poser, ou rien. L'installeur y ajoute sa clause de
#                              decor (sous un decor, tout appartient a qui le joue) : c'est une
#                              identite de rail, elle reste chez lui.
#
# Un hote qui n'en fournirait pas un mourrait a la premiere convergence, pas en silence.
#
# ⚠ `prov_refuse_symlink_path` N'EST PLUS ATTENDU DE L'HOTE : IL VIT ICI (⚖ phase 6, etape 2). Il
# etait declare « identite de rail — son refus porte le vocabulaire du decor », et la mesure du
# 2026-09-20 dit le contraire : les deux corps etaient IDENTIQUES, ligne pour ligne, a la
# ponctuation du message pres. Il n'y avait aucun vocabulaire de decor dedans. Vingt lignes ecrites
# deux fois, dont l'une pouvait deriver sans que rien ne le dise — exactement ce que la premiere
# moitie de la phase 6 a retire pour les cinq autres primitives.

# ⚠ LA GARDE LA PLUS CHERE DU FICHIER : on n'ecrit jamais A TRAVERS un lien. Un seul composant
# symlink sur le chemin d'une mutation privilegiee suffit a faire poser root un fichier ailleurs
# que la ou l'appelant croit — le chemin est donc remonte composant par composant, depuis la racine.
# Un chemin RELATIF est refuse d'entree : il se resout depuis le repertoire courant, que ce fichier
# ne controle pas.
prov_refuse_symlink_path() { # prov_refuse_symlink_path <chemin absolu>
  local path="$1" cur="" part
  local -a parts
  [[ "$path" == /* ]] || { p_fail "mutation privilégiée refusée — chemin relatif : $path"; return 1; }
  IFS='/' read -ra parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      p_fail "mutation privilégiée refusée — composant symlink : $cur -> $(readlink "$cur")"
      return 1
    fi
  done
  return 0
}

# Le champ d'un fichier `CLE=valeur`, lu comme une DONNEE — jamais source, jamais execute. La
# DERNIERE occurrence gagne, comme le ferait un shell qui sourcerait le fichier.
env_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | tail -n1 || true; }

# Un jeton se lit sans blancs, ou rien : jamais un message, jamais un echec. Un fichier absent et un
# fichier vide rendent la meme chose — c'est l'appelant qui sait ce que « pas de jeton » lui fait.
read_token() { # read_token <fichier>
  [[ -n "${1:-}" && -r "$1" ]] && tr -d '[:space:]' < "$1"
  return 0
}

ensure_dir() { # ensure_dir <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir : mkdir refusé : $path"; return 1; }
    _compte_pose; p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}

ensure_mode() { # ensure_mode <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner changed=0
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$path" || return 1
  [[ -e "$path" ]] || { p_fail "ensure_mode : absent : $path"; return 1; }
  cur_mode="$(stat -c '%a' "$path")"
  local want_mode="${mode#0}"
  if [[ "$cur_mode" != "$want_mode" ]]; then
    # les bits SUID/SGID/sticky d'abord : `chmod 0644` ne les retire pas tous sur tout systeme
    chmod u-s,g-s,o-t "$path" 2>/dev/null || true
    chmod "$mode" "$path" || { p_fail "ensure_mode : chmod $mode refusé : $path"; return 1; }
    changed=1
  fi
  if [[ -n "$owner" ]]; then
    cur_owner="$(stat -c '%U:%G' "$path")"
    if [[ "$cur_owner" != "$owner" ]]; then
      chown "$owner" "$path" || { p_fail "ensure_mode : chown $owner refusé : $path"; return 1; }
      changed=1
    fi
  fi
  # ⚠ ON RELIT CE QU'ON VIENT D'ECRIRE, et c'est la garde que l'installeur n'avait pas : `chmod`
  # rend 0 sur un montage qui ignore les permissions, et le mode reste celui d'avant. Sans cette
  # ligne, un objet est annonce POSE avec un mode qu'il ne porte pas.
  [[ "$(stat -c '%a' "$path")" == "$want_mode" ]] \
    || { p_fail "ensure_mode : mode ≠ $want_mode après chmod : $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then _compte_pose; p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}

# ⚠ LE TAMPON EST ECRIT, PUIS BASCULE : `mv` dans le meme dossier est un rename atomique, donc un
# lecteur voit l'ancien contenu ou le nouveau, jamais un fichier a moitie ecrit. Un contenu
# IDENTIQUE ne bascule pas — le fichier garde sa date, et ce qui le surveille ne se reveille pas.
write_atomic() { # write_atomic <dest> <mode> [proprietaire]  < contenu
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$dest" || return 1
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || { p_fail "write_atomic : dossier absent : $dir"; return 1; }
  tmp="$(mktemp "$dir/.prov.XXXXXX")" || { p_fail "write_atomic : tmp impossible dans $dir"; return 1; }
  cat > "$tmp" || { rm -f "$tmp"; p_fail "write_atomic : écriture du tampon ratée (disque plein ? quota ?) : $dest"; return 1; }
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    ensure_mode "$dest" "$mode" "$owner"   # le contenu est bon ; mode et propriétaire convergés à part
    return $?
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic : chmod $mode : $dest"; return 1; }
  if [[ -n "$owner" ]]; then
    chown "$owner" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic : chown $owner : $dest"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; p_fail "write_atomic : mv final : $dest"; return 1; }
  _compte_pose
  p_chg "$dest"
}
