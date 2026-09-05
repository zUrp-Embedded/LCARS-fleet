#!/usr/bin/env bash
# SOURCE: deploy/pkg/gen-contents.sh
# AUTHOR: bob
# STARDATE: 2026-09-05
# STATUS: le generateur des `contents:` nFPM — la table (system.manifest) et l'arbre assemble du
#         pack, UNE source pour les modes et les proprietaires, jamais une seconde table ici
#
# ─── CE QUE CE SCRIPT DERIVE, ET D'OU ──────────────────────────────────────────────────────────
#
# Le `.deb` de `lcars` doit poser EXACTEMENT ce que le rail pose depuis un kit, aux memes modes et
# aux memes proprietaires — sinon `dpkg -V` et `provision doctor` ne mesureraient pas la meme
# machine. Ce script ne porte donc aucune liste de chemins : il lit
#   · `deploy/system.manifest` DU STAGE — les repertoires (`prefix`, `dir`), les ancres et les liens,
#     avec leur mode, leur proprietaire et leur substrat (docker seul : ecarte) ;
#   · `runtime/etc/release.manifest` DU STAGE — ce qui va de `runtime/bin` sous `<prefix>/bin`, et
#     quels liens de PATH `60-deploy` cable (`deploy/lib/deploy-release.sh`) ;
#   · les tableaux de `62-runtime-helpers.sh` DU STAGE — HELPERS, DATA, EMBEDDED, EMBEDDED_ROOT,
#     EMBEDDED_EXCLUDE : ce que le module pose a plat sous la racine, et ce qu'il n'emporte pas ;
#   · les trois arbres que `44-media` pose sous `share/` (avatars, favicon, la doc batie).
# Le seul savoir qui vit ICI est le DECOUPAGE EN PAQUETS (`pkg_of`) : quel chemin appartient a
# `lcars-tofu`, a `lcars-container`, a `lcars-forge` — un fait de packaging, pas de provisionnement.
#
# ⚠ LES MODES DE FICHIERS SUIVENT LES POSEURS, PAS LA TABLE — la table ne declare que des objets
# nommes. Sous le prefixe : `u=rwX,g=rX,o=` (60-deploy) donc 0750/0640 root:<groupe du prefixe>.
# Sous la racine : `g-s,go-w` sur ce que git a donne (62) donc 0755/0644 root:root. Sous `share` :
# `a+rX` (44) donc 0644. Ces trois faits sont ecrits une fois chacun, la ou ils s'appliquent.
#
# ⚠ TOUT EST ENUMERE FICHIER PAR FICHIER, pas par glob : un glob nFPM applique UN mode a tout ce
# qu'il attrape, et un binaire du prefixe n'a pas le mode d'un fichier de config. Et c'est ce qui
# rend le temoin possible — `<out>/<paquet>.paths` est la liste EXACTE de ce que `dpkg-deb -c`
# doit montrer, ancetres implicites compris.
#
# USAGE : gen-contents.sh --stage <lcars_install/> --out <dir> [--tools <dir>] [--pkg-dir <dir>]
#   --stage   la racine du kit assemble par pack.sh (ce que le tar emporte)
#   --out     ou ecrire <paquet>.yaml et <paquet>.paths (un dossier a cote du stage, hors du tar)
#   --tools   le tiroir des outils du pack (`$PACK_DIR/.tools`) : `tofu/{tofu,tofurc,providers}`
#             y attendent pour `lcars-tofu` ; absent, ce paquet-la n'est PAS genere, et c'est dit
#   --pkg-dir ou vivent les YAML statiques (defaut : le dossier de ce script)
# EXIT : 0 · 1 argument ou stage invalide

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="" OUT="" TOOLS="" PKG_DIR="$HERE"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)   STAGE="${2:?--stage attend un dossier}"; shift 2 ;;
    --out)     OUT="${2:?--out attend un dossier}"; shift 2 ;;
    --tools)   TOOLS="${2:?--tools attend un dossier}"; shift 2 ;;
    --pkg-dir) PKG_DIR="${2:?--pkg-dir attend un dossier}"; shift 2 ;;
    -h|--help) sed -n '/^# USAGE/,/^# EXIT/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "gen-contents: option inconnue: $1" >&2; exit 1 ;;
  esac
done
die() { echo "gen-contents: ERREUR — $*" >&2; exit 1; }
say() { echo "gen-contents: $*" >&2; }

[[ -n "$STAGE" && -d "$STAGE" ]] || die "--stage : dossier introuvable (${STAGE:-vide})"
[[ -n "$OUT" ]] || die "--out manquant"
STAGE="$(cd "$STAGE" && pwd)"
mkdir -p "$OUT" || die "sortie inaccessible : $OUT"
OUT="$(cd "$OUT" && pwd)"

MANIFEST="$STAGE/deploy/system.manifest"
RELEASE_MANIFEST="$STAGE/runtime/etc/release.manifest"
MOD62="$STAGE/deploy/modules.d/62-runtime-helpers.sh"
[[ -r "$MANIFEST" ]]         || die "le stage n'a pas de deploy/system.manifest — ce n'est pas un kit"
[[ -r "$RELEASE_MANIFEST" ]] || die "le stage n'a pas de runtime/etc/release.manifest"
[[ -r "$MOD62" ]]            || die "le stage n'a pas de deploy/modules.d/62-runtime-helpers.sh"
[[ -r "$STAGE/.source-revision" ]] \
  || die "le stage n'a pas de .source-revision — pack.sh l'estampille ; sans lui l'install se croirait SOURCE"

PACKAGES=(lcars lcars-workstation lcars-container lcars-forge lcars-bench lcars-demo lcars-tofu lcars-docker-desktop)
for p in "${PACKAGES[@]}"; do [[ -r "$PKG_DIR/$p.yaml" ]] || die "YAML statique absent : $PKG_DIR/$p.yaml"; done

# ─── LA TABLE, LUE UNE FOIS ─────────────────────────────────────────────────────────────────────
rows() { grep -vE '^\s*#|^\s*$' "$MANIFEST"; }

# La racine et le prefixe se LISENT dans la table — aucun chemin d'install n'est ecrit ici.
# ⚠ AUCUN `exit` DANS CES awk : un lecteur qui ferme le tuyau avant la fin envoie SIGPIPE au
# producteur, et sous `pipefail` la substitution rend 141 — le script mourait sans un mot (DI-12).
PREFIX="$(rows | awk '{c=$1; sub(/:.*/,"",c)} c=="prefix" && !v {v=$2} END {print v}')"
[[ -n "$PREFIX" ]] || die "la table ne declare aucun prefix"
PREFIX_MODE="$(rows | awk -v p="$PREFIX" '$2==p && !v {v=$3} END {print v}')"
PREFIX_OWNER="$(rows | awk -v p="$PREFIX" '$2==p && !v {v=$4} END {print v}')"
ROOT="$(dirname "$PREFIX")"
# Le dossier des liens de PATH : celui des `link` que la table declare pour les entrees de release.
LINK_DIR="$(rows | awk '{c=$1; sub(/:.*/,"",c)} c=="link" && $2 !~ /systemd/ && !v {v=$2} END {print v}')"
LINK_DIR="$(dirname "${LINK_DIR:-/usr/local/bin/x}")"

# Les modes derives des poseurs (voir l'en-tete) : sous le prefixe, `u=rwX,g=rX,o=`.
PFX_DIR_MODE="${PREFIX_MODE:-0750}"
PFX_FILE_MODE=0640
PFX_EXEC_MODE=0750
PFX_OWNER="${PREFIX_OWNER:-root:fleet}"
# Sous la racine (62) et sous share (44) : root:root, git decide de l'executable.
ROOT_OWNER=root:root

# ─── LE DECOUPAGE EN PAQUETS — LE SEUL SAVOIR PROPRE A CE SCRIPT ────────────────────────────────
#
#   lcars-tofu       le binaire et le miroir : `<racine>/tofu/**` et `<link_dir>/tofu` (46-tofu)
#   lcars-container  le rail conteneur : `deploy/container` et `deploy/docker/**` — SAUF
#   lcars-forge      les trois fichiers de la forge du poste : forge-compose.yml, runner-compose.yml,
#                    forge-runner.sh (48-forge-host, 49-forge-runner)
#   lcars            tout le reste
pkg_of() { # pkg_of <chemin pose> -> le paquet qui le possede
  local d="$1"
  case "$d" in
    "$ROOT"/tofu|"$ROOT"/tofu/*|"$LINK_DIR"/tofu) echo lcars-tofu ;;
    "$ROOT"/deploy/docker/forge-compose.yml|"$ROOT"/deploy/docker/runner-compose.yml|"$ROOT"/deploy/docker/forge-runner.sh) echo lcars-forge ;;
    "$ROOT"/deploy/container|"$ROOT"/deploy/docker|"$ROOT"/deploy/docker/*) echo lcars-container ;;
    *) echo lcars ;;
  esac
}

# ─── L'EMISSION ─────────────────────────────────────────────────────────────────────────────────
declare -A SEEN=()      # dst -> paquet : un objet n'entre qu'une fois, la table gagne sur l'arbre
declare -A COUNT=()
for p in "${PACKAGES[@]}"; do : > "$OUT/.$p.contents"; : > "$OUT/.$p.paths"; COUNT[$p]=0; done

note_path() { # note_path <paquet> <dst> — le chemin ET ses ancetres implicites (nFPM les ajoute)
  local p="$1" d="$2"
  printf '%s\n' "$d" >> "$OUT/.$p.paths"
  while d="$(dirname "$d")"; [[ "$d" != "/" ]]; do printf '%s\n' "$d" >> "$OUT/.$p.paths"; done
}
file_info() { # file_info <mode> <owner> -> le bloc YAML
  printf '    file_info:\n      mode: %s\n      owner: %s\n      group: %s\n' "$1" "${2%%:*}" "${2##*:}"
}
emit_dir() { # emit_dir <dst> <mode> <owner>
  local d="$1" p; p="$(pkg_of "$d")"
  [[ -z "${SEEN[$d]:-}" ]] || return 0
  SEEN[$d]="$p"
  { printf '  - dst: "%s"\n    type: dir\n' "$d"; file_info "$2" "$3"; } >> "$OUT/.$p.contents"
  note_path "$p" "$d"; COUNT[$p]=$((COUNT[$p] + 1))
}
emit_file() { # emit_file <src> <dst> <mode> <owner> [type]
  local s="$1" d="$2" p; p="$(pkg_of "$d")"
  [[ -z "${SEEN[$d]:-}" ]] || return 0
  SEEN[$d]="$p"
  { printf '  - src: "%s"\n    dst: "%s"\n' "$s" "$d"
    [[ -z "${5:-}" ]] || printf '    type: %s\n' "$5"
    file_info "$3" "$4"; } >> "$OUT/.$p.contents"
  note_path "$p" "$d"; COUNT[$p]=$((COUNT[$p] + 1))
}
emit_link() { # emit_link <cible> <dst>
  local t="$1" d="$2" p; p="$(pkg_of "$d")"
  [[ -z "${SEEN[$d]:-}" ]] || return 0
  SEEN[$d]="$p"
  printf '  - src: "%s"\n    dst: "%s"\n    type: symlink\n' "$t" "$d" >> "$OUT/.$p.contents"
  note_path "$p" "$d"; COUNT[$p]=$((COUNT[$p] + 1))
}

# emit_tree <src> <dst> <dir_mode> <file_mode> <exec_mode> <owner> [motif find a elaguer]...
# Chaque objet de l'arbre, un par un ; les liens symboliques restent des liens.
emit_tree() {
  local src="$1" dst="$2" dm="$3" fm="$4" xm="$5" own="$6"; shift 6
  local -a prune=()
  local x
  for x in "$@"; do prune+=(-name "$x" -o); done
  [[ -d "$src" ]] || die "arbre absent du stage : $src"
  local f rel
  while IFS= read -r f; do
    rel="${f#"$src"}"
    if [[ -L "$f" ]]; then emit_link "$(readlink "$f")" "$dst$rel"
    elif [[ -d "$f" ]]; then emit_dir "$dst$rel" "$dm" "$own"
    elif [[ -x "$f" ]]; then emit_file "$f" "$dst$rel" "$xm" "$own"
    else emit_file "$f" "$dst$rel" "$fm" "$own"
    fi
  done < <(find "$src" -mindepth 1 \( "${prune[@]}" -false \) -prune -o -print | LC_ALL=C sort)
}

# array_of <fichier> <NOM> -> les elements du tableau bash NOM tel que le fichier le declare.
# Le bloc est evalue dans un sous-shell : ce sont NOS fichiers, et les variables qu'ils citent
# (HELPERS_DIR, LCARS_BASHRC dans DATA) sont posees a la valeur que le module leur donne.
array_of() {
  local f="$1" n="$2" blk
  blk="$(sed -n "/^$n=(/,/^)/p" "$f")"
  [[ -n "$blk" ]] || blk="$(grep -E "^$n=\(.*\)\$" "$f" || true)"
  [[ -n "$blk" ]] || die "tableau $n introuvable dans $f"
  ( HELPERS_DIR="$ROOT"; LCARS_BASHRC="$ETC_DIR/lcars.bashrc"; export HELPERS_DIR LCARS_BASHRC
    eval "$blk"; eval 'printf "%s\n" "${'"$n"'[@]}"' )
}

# ─── 1. LA TABLE : repertoires, ancres, liens ───────────────────────────────────────────────────
#
# Ce que le .deb ne porte PAS, et pourquoi — chaque classe ecartee a sa raison :
#   runtime           /run est un tmpfs : 25-directories pose la declaration tmpfiles, le boot les refait
#   group, account    postinst (20-groups, 21-service-accounts) — un paquet ne porte pas un uid
#   human, person     jamais sous /home
#   preserve          du travail, pas du produit
#   anchor sans source dans le stage (unites systemd, seat.uid, services.env, deck-oidc.json,
#                     host-consent, tmpfiles) : leur contenu est DERIVE par un module, au postinst
#   link .wants       poses par `systemctl enable` (64-services), jamais par nous
#   substrat docker   l'image se batit par le Dockerfile, pas par apt
#   jokers <version>, <human>   un objet dont le nom se resout a l'execution n'est pas empaquetable
ETC_DIR="$(rows | awk '{c=$1; sub(/:.*/,"",c)} c=="dir" && $2 ~ /^\/etc\/[a-z]+$/ && !v {v=$2} END {print v}')"
: "${ETC_DIR:=/etc/lcars}"
applies() { # applies <colonne substrat> -> 0 si un POSTE (wsl ou linux) porte l'objet
  case ",${1//+/,}," in *,any,*|*,wsl,*|*,linux,*) return 0 ;; esac
  return 1
}
SKIPPED=()
while read -r cls obj mode owner sub; do
  c="${cls%%:*}"
  case "$c" in
    prefix|dir) ;;
    anchor|link) continue ;;                       # traites plus bas, avec leur source
    *) continue ;;
  esac
  [[ "$obj" != *"<"*">"* ]] || { SKIPPED+=("$obj (joker)"); continue; }
  case "$obj" in /home|/home/*|/root|/root/*) SKIPPED+=("$obj (hors perimetre d'un paquet)"); continue ;; esac
  applies "$sub" || { SKIPPED+=("$obj (substrat $sub)"); continue; }
  [[ "$mode" != "-" ]] || mode=0755
  [[ "$owner" != "-" ]] || owner="$ROOT_OWNER"
  emit_dir "$obj" "$mode" "$owner"
done < <(rows)

# Les ancres qui ont une SOURCE dans le stage — la table dit le mode et le proprietaire, le stage
# donne les octets. `.helpers-revision` est le tampon que 62 ecrit a l'apply : sous dpkg il vaut
# ce que `.source-revision` vaut (les auxiliaires sortent du meme arbre), et il voyage avec eux.
REV="$(head -n1 "$STAGE/.source-revision" | tr -d '[:space:]')"
printf '%s\n' "$REV" > "$OUT/helpers-revision"
anchor_src() { # anchor_src <chemin d'ancre> -> la source dans le stage, ou vide
  case "$1" in
    "$ROOT"/.source-revision)              echo "$STAGE/.source-revision" ;;
    "$ROOT"/.helpers-revision)             echo "$OUT/helpers-revision" ;;
    "$LINK_DIR"/lcars-toolchain-converge)  echo "$STAGE/runtime/bin/lcars-toolchain-converge" ;;
    "$LINK_DIR"/lcars-authority-ask)       echo "$STAGE/runtime/bin/lcars-authority-ask" ;;
    "$ETC_DIR"/lcars.bashrc)               echo "$STAGE/runtime/services/lcars.bashrc" ;;
    "$LINK_DIR"/tofu)                      [[ -n "$TOOLS" && -x "$TOOLS/tofu/tofu" ]] && echo "$TOOLS/tofu/tofu" || true ;;
  esac
}
anchor_type() { case "$1" in "$ETC_DIR"/*) echo config ;; esac; }   # /etc/lcars : conffiles dpkg
while read -r cls obj mode owner sub; do
  c="${cls%%:*}"; t="${cls#*:}"; [[ "$t" != "$cls" ]] || t=""
  [[ "$c" == "anchor" ]] || continue
  [[ "$t" != "merge" ]] || { SKIPPED+=("$obj (merge : le fichier est a quelqu'un d'autre)"); continue; }
  applies "$sub" || { SKIPPED+=("$obj (substrat $sub)"); continue; }
  src="$(anchor_src "$obj")"
  if [[ -z "$src" ]]; then SKIPPED+=("$obj (ancre derivee au postinst, pas dans le stage)"); continue; fi
  [[ -r "$src" ]] || die "ancre $obj : source absente du stage ($src)"
  emit_file "$src" "$obj" "$mode" "$owner" "$(anchor_type "$obj")"
done < <(rows)

# Les liens de PATH : ceux que `release.manifest` marque `link` et que la table declare — cables
# par 60-deploy vers `<prefix>/bin/<nom>`. Les autres liens de la table (node, npm, npx : le
# toolchain d'une livraison SOURCE ; les .wants de systemd) ne sont pas a un paquet binaire.
rel_entries() { awk 'NF && $1 !~ /^#/ { print $1, $2, ($3 == "link" ? 1 : 0) }' "$RELEASE_MANIFEST"; }
while read -r cls obj _ _ sub; do
  c="${cls%%:*}"
  [[ "$c" == "link" ]] || continue
  applies "$sub" || { SKIPPED+=("$obj (substrat $sub)"); continue; }
  name="${obj##*/}"
  if [[ "$(dirname "$obj")" == "$LINK_DIR" ]] && [[ -n "$(rel_entries | awk -v n="$name" '$1==n && $3==1')" ]]; then
    emit_link "$PREFIX/bin/$name" "$obj"
  else
    SKIPPED+=("$obj (lien pose par un autre geste)")
  fi
done < <(rows)

# ─── 2. LE PREFIXE : ce que deploy-release.sh pose (60-deploy) ──────────────────────────────────
REL_SRC="$STAGE/runtime/_build/prod/rel/lcars_fleet"
[[ -x "$REL_SRC/bin/lcars_fleet" ]] || die "le stage ne porte pas de release ($REL_SRC/bin/lcars_fleet) — pack.sh la batit avant"
emit_dir "$PREFIX/rel" "$PFX_DIR_MODE" "$PFX_OWNER"
emit_dir "$PREFIX/bin" "$PFX_DIR_MODE" "$PFX_OWNER"
emit_dir "$PREFIX/etc" "$PFX_DIR_MODE" "$PFX_OWNER"
emit_dir "$PREFIX/rel/lcars_fleet" "$PFX_DIR_MODE" "$PFX_OWNER"
emit_tree "$REL_SRC" "$PREFIX/rel/lcars_fleet" "$PFX_DIR_MODE" "$PFX_FILE_MODE" "$PFX_EXEC_MODE" "$PFX_OWNER"
while read -r name mode _; do
  [[ -r "$STAGE/runtime/bin/$name" ]] || die "release.manifest nomme bin/$name, absent du stage"
  if [[ "$mode" == "exec" ]]; then m="$PFX_EXEC_MODE"; else m="$PFX_FILE_MODE"; fi
  emit_file "$STAGE/runtime/bin/$name" "$PREFIX/bin/$name" "$m" "$PFX_OWNER"
done < <(rel_entries)
[[ -r "$STAGE/runtime/etc/fleet.env.template" ]] || die "runtime/etc/fleet.env.template absent du stage"
emit_file "$STAGE/runtime/etc/fleet.env.template" "$PREFIX/etc/fleet.env.template" "$PFX_FILE_MODE" "$PFX_OWNER"

# ─── 3. LA RACINE : ce que 62-runtime-helpers embarque et pose a plat ───────────────────────────
mapfile -t EXCL < <(array_of "$MOD62" EMBEDDED_EXCLUDE | sed 's/^--exclude=//')
while read -r h; do
  [[ -n "$h" ]] || continue
  [[ -r "$STAGE/runtime/services/$h" ]] || die "62 nomme l'auxiliaire $h, absent du stage"
  emit_file "$STAGE/runtime/services/$h" "$ROOT/$h" 0755 "$ROOT_OWNER"
done < <(array_of "$MOD62" HELPERS)
while read -r d_src d_dst d_mode; do
  [[ -n "$d_src" ]] || continue
  [[ -r "$STAGE/runtime/services/$d_src" ]] || die "62 nomme la donnee $d_src, absente du stage"
  emit_file "$STAGE/runtime/services/$d_src" "$d_dst" "$d_mode" "$ROOT_OWNER" "$(anchor_type "$d_dst")"
done < <(array_of "$MOD62" DATA)
while read -r n; do
  [[ -n "$n" ]] || continue
  emit_dir "$ROOT/$n" 0755 "$ROOT_OWNER"
  emit_tree "$STAGE/runtime/$n" "$ROOT/$n" 0755 0644 0755 "$ROOT_OWNER" "${EXCL[@]}"
done < <(array_of "$MOD62" EMBEDDED)
while read -r n; do
  [[ -n "$n" ]] || continue
  emit_dir "$ROOT/$n" 0755 "$ROOT_OWNER"
  # ⚖ user 2026-09-04 (Q2) : deploy s'embarque SANS ses tests — la meme borne que 62.
  if [[ "$n" == deploy ]]; then
    emit_tree "$STAGE/$n" "$ROOT/$n" 0755 0644 0755 "$ROOT_OWNER" "${EXCL[@]}" tests
  else
    emit_tree "$STAGE/$n" "$ROOT/$n" 0755 0644 0755 "$ROOT_OWNER" "${EXCL[@]}"
  fi
done < <(array_of "$MOD62" EMBEDDED_ROOT)

# ─── 4. SHARE : ce que 44-media pose (les medias, et la doc batie par pack.sh) ──────────────────
for t in avatars favicon; do
  [[ -d "$STAGE/assets/$t" ]] || die "assets/$t absent du stage — 44-media en depend"
  emit_tree "$STAGE/assets/$t" "$ROOT/share/$t" 0755 0644 0644 "$ROOT_OWNER"
done
[[ -s "$STAGE/assets/github.io/dist/index.html" ]] \
  || die "la doc batie manque au stage (assets/github.io/dist/index.html) — un paquet sans sa doc est une demi-livraison"
emit_tree "$STAGE/assets/github.io/dist" "$ROOT/share/doc" 0755 0644 0644 "$ROOT_OWNER"

# ─── 5. LCARS-TOFU : le binaire, le tofurc, le miroir — depuis le tiroir des outils ─────────────
WITH_TOFU=0
if [[ -n "$TOOLS" && -x "$TOOLS/tofu/tofu" && -s "$TOOLS/tofu/tofurc" && -d "$TOOLS/tofu/providers" ]]; then
  WITH_TOFU=1
  emit_file "$TOOLS/tofu/tofurc" "$ROOT/tofu/tofurc" 0644 "$ROOT_OWNER"
  emit_tree "$TOOLS/tofu/providers" "$ROOT/tofu/providers" 0755 0644 0755 "$ROOT_OWNER"
else
  say "lcars-tofu : pas d'outillage complet sous ${TOOLS:-<--tools absent>}/tofu (tofu, tofurc, providers/) — paquet NON genere"
fi

# ─── LES YAML : le statique de deploy/pkg, puis `contents:` ─────────────────────────────────────
GENERATED=()
for p in "${PACKAGES[@]}"; do
  if [[ "$p" == lcars-tofu && "$WITH_TOFU" -eq 0 ]]; then rm -f "$OUT/.$p.contents" "$OUT/.$p.paths"; continue; fi
  {
    # les scripts se resolvent depuis le dossier des YAML, pas depuis le cwd de nfpm
    sed -E "s#^(\s*(pre|post)(install|remove):\s*)\./#\1$PKG_DIR/#" "$PKG_DIR/$p.yaml"
    echo
    echo "# ─── GENERE par deploy/pkg/gen-contents.sh depuis le stage $STAGE ─── ne pas editer ───"
    if [[ "${COUNT[$p]}" -gt 0 ]]; then
      echo "contents:"; cat "$OUT/.$p.contents"
    else
      echo "# (aucun contenu : un paquet de gestes, ou un meta-paquet)"
    fi
    if [[ "$p" == lcars && "${#SKIPPED[@]}" -gt 0 ]]; then
      echo "# ─── objets de la table que ce paquet ne porte PAS (poses par le provisionnement, ou hors perimetre) :"
      printf '#   %s\n' "${SKIPPED[@]}"
    fi
  } > "$OUT/$p.yaml"
  LC_ALL=C sort -u "$OUT/.$p.paths" > "$OUT/$p.paths"
  rm -f "$OUT/.$p.contents" "$OUT/.$p.paths"
  GENERATED+=("$p")
  say "$p : ${COUNT[$p]} objet(s) declares, $(wc -l < "$OUT/$p.paths") chemin(s) attendus"
done
printf '%s\n' "${GENERATED[@]}" > "$OUT/packages.list"
say "${#GENERATED[@]} YAML dans $OUT (liste : $OUT/packages.list)"
