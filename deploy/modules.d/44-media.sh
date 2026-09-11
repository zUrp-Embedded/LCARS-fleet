#!/usr/bin/env bash
# SOURCE: deploy/modules.d/44-media.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — les médias partagés (avatars, favicon) : le jumeau FICHIER du trou ISO des paquets
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 16-node

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Le seam est celui du PRODUIT : `runtime.exs` lit `LCARS_MEDIA_ROOT` avec ce même défaut, et
# `deck.ex` le documente. On n'en invente pas un second.
MEDIA_ROOT_CANON="$PROV_ROOT/share"   # le chemin que deploy/system.manifest declare (dir share, share/*)
MEDIA_ROOT="${LCARS_MEDIA_ROOT:-$MEDIA_ROOT_CANON}"
# ⚠ LE MODE ET LE PROPRIETAIRE VIENNENT DE LA TABLE, PLUS D'UN LITTERAL (lot 15). Ce module POSE
# `share` et ses trois sous-arbres ; il est donc le seul a pouvoir relire leur mode — les ajouter a
# la table de `25-directories` en ferait un second poseur (mur POSEUR). La table les declarait
# `0755 root:root` et AUCUN module ne les mesurait : un `share/avatars` en 2775 (setgid herite
# d'un checkout, ou d'un COPY depuis un contexte a umask 002) passait un doctor vert.
# Le proprietaire garde sa couture de decor (un temoin ne chown pas vers root) ; repli sur les
# valeurs historiques si la table ne dit rien.
MEDIA_OWNER="${LCARS_MEDIA_OWNER:-$(prov_manifest_owner "$MEDIA_ROOT_CANON")}"
: "${MEDIA_OWNER:=root:root}"
media_mode() { # media_mode [sous-arbre] -> le mode que la table declare pour share[/<sous-arbre>], sinon 0755
  local m; m="$(prov_manifest_mode "$MEDIA_ROOT_CANON${1:+/$1}")"; printf '%s\n' "${m:-0755}"
}
# media_check_perms [sous-arbre] — le mode et le proprietaire RELUS (stat), contre la table. Un objet
# absent n'est pas juge ici : son absence se dit une fois, la ou elle a une consequence.
media_check_perms() {
  local path="$MEDIA_ROOT${1:+/$1}" cur want
  [[ -d "$path" ]] || return 0
  cur="$(stat -c '%a %U:%G' "$path")"
  want="$(media_mode "${1:-}") $MEDIA_OWNER"; want="${want#0}"
  if [[ "$cur" == "$want" ]]; then
    p_ok "$path $cur (table)"
  else
    p_drift "$path : $cur ≠ $want (deploy/system.manifest) — l'apply le repose"
  fi
}

MEDIA_TREES=(avatars favicon)

MEDIA_SRC_ROOT="${LCARS_MEDIA_SRC_ROOT:-$(repo_root)/assets}"

media_src() { echo "$MEDIA_SRC_ROOT/$1"; }

SITE_SRC="${LCARS_SITE_SRC:-$(repo_root)/assets/github.io}"
SITE_BASE="${LCARS_SITE_BASE:-/doc/}"
NPM_BIN="${LCARS_NPM_BIN:-npm}"

doc_dir() { echo "$MEDIA_ROOT/doc"; }
# ⚠ LE TAMPON DE LA DOC — SANS LUI, CE MODULE REBÂTIT ET REPOSE À CHAQUE APPLY. Mesuré le
# 2026-09-08 sur le banc 2005 : trois `provision apply` de suite, douze objets « POSÉ » stables,
# dont `share/doc/index.html` dont le mtime CHANGE à chaque passage. Deux gestes non idempotents
# l'un derrière l'autre : `npm ci` + `npm run build`, puis `poser_doc` qui remplace l'arbre ENTIER
# (scaffold + promote). Le journal D1 du 2026-09-01 affirmait « apply sur état complet → 0
# changement » et disait que c'était le plus fort des deux tests ; il ne passait plus, et rien ne
# le rejouait.
#
# Le tampon vit À CÔTÉ de `doc/`, pas dedans : `prov_promote_dir` remplace le répertoire final, il
# emporterait un tampon qui y serait posé. Même motif que `.helpers-revision` de `62`.
doc_stamp() { echo "$MEDIA_ROOT/.doc-revision"; }
# doc_empreinte -> une signature du `dist/` qui va etre pose, et de la BASE qui l'a batie
#
# ⚠ LA REVISION SEULE NE SUFFIT A AUCUN DES TROIS CHEMINS DE POSE. Mesures du 2026-09-08 :
#   · `LCARS_SITE_BASE` change le site sans changer la revision — un tampon qui ne porte que la
#     revision declare « a jour » une doc batie pour une AUTRE base, dont chaque URL d'asset est
#     fausse ;
#   · `prov_source_rev` ne suffixe « +local » que sur un fichier SUIVI : un fichier neuf, pas encore
#     ajoute, laisse la revision propre et le court-circuit saute un build qu'il fallait faire ;
#   · les deux chemins de LIVRAISON BINAIRE (`prov_dans_la_copie`, `dist/` embarque) reposent la doc
#     ENTIERE a chaque apply — ils rendent avant le court-circuit, qui ne les a jamais couverts.
# Une empreinte du `dist/` reellement pose repond aux trois : elle change quand le build a retourne,
# elle ne change pas sur une livraison figee, et elle ne demande aucun git.
doc_empreinte() {
  [[ -d "$SITE_SRC/dist" ]] || return 1
  { printf 'base=%s\n' "$SITE_BASE"
    find "$SITE_SRC/dist" -printf '%P %s %T@\n' 2>/dev/null | LC_ALL=C sort
  } | sha256sum | cut -d' ' -f1
}
# doc_tampon_lit <cle> -> la valeur de cette cle dans le tampon, ou rien
doc_tampon_lit() { sed -n "s/^$1 //p" "$(doc_stamp)" 2>/dev/null | head -n1; }
# doc_a_jour -> 0 si la doc posée sort de CETTE révision, et qu'on peut l'affirmer
#
# ⚠ UN ARBRE MODIFIÉ NE COURT-CIRCUITE JAMAIS. `prov_source_rev` suffixe « +local » dès qu'un
# fichier suivi diffère — mais le suffixe est le MÊME pour deux modifications différentes. Un
# tampon « abc12345+local » ne dirait donc pas si le site a changé depuis le dernier build. Sur un
# arbre sale on rebâtit, faute de pouvoir savoir ; sur un arbre propre — le banc, la production —
# la comparaison est exacte.
doc_a_jour() {
  local rev; rev="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  [[ -n "$rev" && "$rev" != "inconnue" && "$rev" != *"+local" ]] || return 1
  [[ -s "$(doc_dir)/index.html" ]] || return 1
  [[ -r "$(doc_stamp)" ]] || return 1
  # ⚠ ET LE TROU DES FICHIERS NON SUIVIS SE FERME ICI. « +local » ne parle que des fichiers que git
  # SUIT ; un fichier neuf sous `assets/github.io` laisse la revision propre, et le court-circuit
  # sautait alors un build qu'il fallait faire. `--untracked-files=all` sur CE sous-arbre le voit.
  # Sur une machine sans depot, la commande echoue : on ne court-circuite pas, ce qui est le bon
  # defaut — c'est deja ce que fait la revision « inconnue ».
  local sale
  sale="$(git -C "$SITE_SRC" status --porcelain --untracked-files=all -- . 2>/dev/null)" || return 1
  [[ -z "$sale" ]] || return 1
  [[ "$(doc_tampon_lit rev)" == "$rev" ]] || return 1
  # La BASE fait partie du produit : le meme commit bati sous « / » et sous « /doc/ » ne donne pas
  # le meme site, et rien d'autre ne le dirait.
  [[ "$(doc_tampon_lit base)" == "$SITE_BASE" ]]
}

check() {
  local t src n
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    if [[ ! -d "$MEDIA_ROOT/$t" ]]; then
      p_drift "$MEDIA_ROOT/$t absent — la charte de forge échoue dessus, et le deck sert des icônes génériques"
      continue
    fi
    # ⚠ LA PRÉSENCE DU RÉPERTOIRE NE SUFFIT PAS. Un dossier vide passe un test d'existence et fait
    # échouer la recette exactement pareil. On compare les COMPTES, qui est la question posée.
    n="$(find "$MEDIA_ROOT/$t" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    if [[ -d "$src" ]] && (( n < $(find "$src" -maxdepth 1 -type f | wc -l) )); then
      p_drift "$MEDIA_ROOT/$t incomplet ($n fichiers) — la source en porte plus ($src)"
    else
      p_ok "$MEDIA_ROOT/$t posé ($n fichiers)"
    fi
    media_check_perms "$t"
  done

  # ⚠ ON SONDE `index.html`, PAS LE RÉPERTOIRE. Un build interrompu laisse un `doc/` qui existe et
  # que la route sert en 404 — la question posée est « le deck a-t-il une page d'accueil à rendre »,
  # et c'est ce fichier-là qui y répond.
  if [[ -s "$(doc_dir)/index.html" ]]; then
    p_ok "$(doc_dir) posée ($(find "$(doc_dir)" -type f 2>/dev/null | wc -l) fichiers)"
  else
    p_drift "$(doc_dir) absente — l'onglet Doc du deck rendra 404 (16-node la bâtit, ce module la pose)"
  fi
  media_check_perms doc
  media_check_perms   # la racine `share` elle-meme, declaree comme les trois autres

  verdict_check
}

build_doc() {
  [[ -d "$SITE_SRC" ]] \
    || { p_fail "sources du site absentes ($SITE_SRC) — l'arbre livre-t-il encore sa doc ?"; verdict_apply; }

  # ⚠ EN LIVRAISON BINAIRE, ON NE BÂTIT PAS — ON POSE CE QUI EST ARRIVÉ BÂTI. `pack.sh` emporte le
  # `dist/` à ce chemin exact, à côté de la release et pour la même raison : les deux sont
  # gitignorés, donc `git archive` ne les emporte pas, donc le paquet les ajoute.
  #
  # Sans cette branche, une cible qui installe un paquet mourait ICI. `16-node` ne pose plus node en
  # livraison binaire — c'est le geste R4 — donc `npm` est absent, et ce module échouait sur un
  # « joue-le d'abord » qui désigne un module dont l'état-cible est justement de ne rien poser. Le
  # rail s'envoyait à lui-même une instruction impossible.
  if prov_delivery_is_binary; then
    [[ -s "$SITE_SRC/dist/index.html" ]] \
      || { p_fail "livraison binaire, mais le paquet n'apporte pas la doc bâtie ($SITE_SRC/dist) — « pack.sh » la bâtit ET l'emporte ; ce paquet est une demi-livraison"; verdict_apply; }
    poser_doc
    return 0
  fi

  # ⚠ LA COPIE POSÉE N'EST PAS UN ARBRE DE BUILD, ET CELUI-CI Y INSTALLAIT 176 Mo AVANT D'ÉCHOUER.
  # La branche du dessus lit la LIVRAISON ; celle-ci lit l'EMPLACEMENT, et les deux questions sont
  # distinctes. Un poste en livraison SOURCE rejoué depuis `/opt/lcars` arrivait ici, lançait
  # `npm ci` dans `/opt/lcars/assets/github.io` — que `62-runtime-helpers` embarque justement SANS
  # `node_modules` — puis mourait sur `npm run build`.
  #
  # VU : `FAIL 44-media: build du site en échec`, et
  # `/opt/lcars/assets` pesant 176 Mo au relevé suivant. L'échec était visible ; la pollution, non.
  #
  # Le `dist/` embarqué EST la doc de cette machine. S'il manque, c'est un drift à nommer — pas un
  # build à lancer depuis un arbre qui n'a jamais eu vocation à en porter un.
  if prov_dans_la_copie; then
    if [[ -s "$SITE_SRC/dist/index.html" ]]; then
      poser_doc
      return 0
    fi
    p_drift "doc non bâtie dans la copie posée ($SITE_SRC/dist) — ce rail se REJOUE ici, il ne s'y reconstruit pas : relance l'apply depuis l'arbre de travail"
    return 0
  fi

  # LE COURT-CIRCUIT, AVANT `npm` : rebâtir ce qui est déjà posé pour cette révision coûte un
  # `npm ci` + un build à chaque convergence, et fait mentir le compteur de changement.
  if doc_a_jour; then
    p_ok "doc du deck à jour ($(doc_dir), révision $(prov_source_rev)) — rien à rebâtir"
    return 0
  fi
  command -v "$NPM_BIN" >/dev/null 2>&1 \
    || { p_fail "npm absent — 16-node pose le précompilé épinglé ; joue-le d'abord"; verdict_apply; }

  # ⚠ `as_human` : `npm ci` ÉCRIT dans le checkout (`node_modules/`, `dist/`, tous deux gitignorés).
  run_step "doc du deck · dépendances" -- as_human env -C "$SITE_SRC" "$NPM_BIN" ci --no-audit --no-fund \
    || { p_fail "npm ci en échec ($SITE_SRC) — la doc ne peut pas être bâtie"; verdict_apply; }

  # ⚠ LA BASE VOYAGE PAR L'ENVIRONNEMENT, et sans elle le site sort pour la racine : servi sous
  # `/doc/`, chacune de ses URL d'asset serait fausse. C'est la variable que le Dockerfile pose, et
  # que le workflow GitHub NE pose pas — Pages sert au domaine, le deck sous un chemin.
  run_step "doc du deck · build" -- as_human env -C "$SITE_SRC" LCARS_SITE_BASE="$SITE_BASE" "$NPM_BIN" run build \
    || { p_fail "build du site en échec ($SITE_SRC) — un chemin du runtime a-t-il bougé ? le build LIT l'arbre"; verdict_apply; }

  [[ -s "$SITE_SRC/dist/index.html" ]] \
    || { p_fail "build terminé sans index.html ($SITE_SRC/dist) — rien à servir"; verdict_apply; }

  poser_doc
}

# ⚠ LA POSE EST COMMUNE AUX DEUX LIVRAISONS, ET C'EST DELIBERE. Ce qui change entre binaire et
# source est de savoir QUI a bâti le `dist/` — pas ce qu'on en fait. Deux copies de ce bloc
# dériveraient sur le mode, le propriétaire ou l'atomicité, et l'une des deux formes servirait une
# doc que personne n'a relue.
poser_doc() {
  # Pose atomique : un `doc/` à moitié recopié se sert en 404 silencieux.
  local partial; partial="$(doc_dir).partial"
  rm -rf "$partial"
  prov_scaffold_dir "$partial" "$(media_mode doc)" "$MEDIA_OWNER" || verdict_apply   # hors journal (M8)
  # ⚠ LE COURT-CIRCUIT EST *ICI*, PAS SEULEMENT AVANT `npm` — SINON IL NE COUVRE QU'UN CHEMIN SUR
  # TROIS. Les deux branches de livraison binaire appellent `poser_doc` et rendent AVANT d'atteindre
  # `doc_a_jour` : sur une machine posée par un .deb ou par l'image, l'arbre `doc/` était donc
  # remplacé en entier à chaque apply, et un `p_chg` imprimé — exactement le défaut que ce chantier
  # nomme, sur le rail où il est le plus visible. L'empreinte, elle, ne demande pas de git.
  local emp; emp="$(doc_empreinte || true)"
  if [[ -n "$emp" && "$emp" == "$(doc_tampon_lit dist)" && -s "$(doc_dir)/index.html" ]]; then
    p_ok "doc du deck déjà posée ($(doc_dir), base $SITE_BASE) — rien à poser"
    return 0
  fi
  # ⚠ LE MÊME `cp -a "…/."` QUE LA BOUCLE DES MÉDIAS, ET LE MÊME DÉFAUT. Le `.` désigne le
  # RÉPERTOIRE SOURCE : `cp -a` recopie donc SES attributs sur `$partial`, écrasant le mode et le
  # propriétaire que `prov_scaffold_dir` vient de poser deux lignes plus haut — par ceux du
  # checkout, c'est-à-dire un humain. Les `find` d'`apply` le rattrapaient ensuite, en comptant une
  # mutation à chaque passe. Corrigé ici comme là-bas : `-H` pour qu'une source liée ne copie pas
  # zéro fichier en silence, `+` pour que l'échec d'un `cp` ne rende pas 0.
  find -H "$SITE_SRC/dist" -mindepth 1 -maxdepth 1 -exec cp -a -t "$partial/" {} + \
    || { p_fail "doc non copiable ($SITE_SRC/dist → $(doc_dir))"; rm -rf "$partial"; verdict_apply; }
  prov_promote_dir "$partial" "$(doc_dir)" || verdict_apply   # journalise le nom FINAL
  # Le tampon APRÈS la pose : il atteste ce qui est en place, jamais une intention. Trois champs,
  # parce que trois questions distinctes se posent — la révision et la base pour éviter le BUILD,
  # l'empreinte pour éviter la POSE. Une révision « inconnue » ou « +local » n'est pas écrite : un
  # tampon qu'on ne pourra pas comparer ne dit rien. L'empreinte, elle, s'écrit toujours.
  # ⚠ PAS `{ … } | write_atomic` : MUR I1bis. Le dernier maillon d'un pipeline est un sous-shell,
  # `PROV_CHANGED` y serait incrémenté puis PERDU — le fichier écrit, l'apply annonçant « rien
  # changé ». C'est le défaut que `25-directories` a déjà payé, et je l'ai réintroduit ici en
  # écrivant ce tampon ; le corpus de ce module l'a rendu visible en mesurant le compteur.
  local rev tampon=""
  rev="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  if [[ -n "$rev" && "$rev" != "inconnue" && "$rev" != *"+local" ]]; then
    tampon+="rev $rev"$'\n'"base $SITE_BASE"$'\n'
  fi
  [[ -n "$emp" ]] && tampon+="dist $emp"$'\n'
  [[ -n "$tampon" ]] && { write_atomic "$(doc_stamp)" 0644 "$MEDIA_OWNER" <<<"${tampon%$'\n'}" || true; }
  # ⚠ ET LE COMPTEUR, QUI MANQUAIT DEPUIS TOUJOURS. `p_chg` IMPRIME, il ne compte pas — c'est
  # l'appelant qui compte (`provision-lib.sh` le fait à chaque poseur), et `prov_promote_dir` ne
  # compte pas non plus. `poser_doc` annonçait donc « POSÉ doc du deck posée » sans que le bilan de
  # l'apply n'enregistre le moindre changement : le compteur mentait dans l'autre sens, celui qu'on
  # ne soupçonne pas. Trouvé le 2026-09-08 par le corpus neuf de ce module, en mesurant PROV_CHANGED.
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "doc du deck posée ($(doc_dir), base $SITE_BASE)"
}

# media_modes <racine> — les deux chmod filtres, dans une fonction NOMMEE
#
# ⚠ EXTRAITE POUR ETRE MESURABLE, ET C'EST LA SEULE RAISON. Ces filtres sont ce qu'un correctif
# d'idempotence a de plus fragile : trop larges ils reposent tout a chaque apply, trop etroits ils
# sautent un geste utile en silence — et les deux fautes sont invisibles a la lecture. Inlines dans
# `apply`, ils ne se jouaient que sous root sur une vraie machine, donc jamais dans la porte.
# Ici un temoin les joue sur un bac a sable (`44-media.bats`, LES MODES).
media_modes() {
  local racine="${1:?media_modes: racine absente}" rc=0
  find "$racine" -mindepth 2 -type d \( -perm /7022 -o ! -perm -u=rwx -o ! -perm -go=rx \) \
    -exec chmod a-s,u=rwx,go=rx {} + || { p_warn "mode dossiers non posé sous $MEDIA_ROOT"; rc=1; }
  # ⚠ LE FILTRE DES FICHIERS RATAIT SIX MODES. `! -perm -a=r` ne voit que l'absence de LECTURE ;
  # `a+rX` pose AUSSI le `x` sur tout le monde dès qu'un `x` existe quelque part. Mesuré le
  # 2026-09-08, ancien mode → ce que `a+rX` rend → sélectionné par l'ancien filtre :
  #     744 → 755 : NON     754 → 755 : NON     764 → 775 : NON
  #     774 → 775 : NON     654 → 755 : NON     745 → 755 : NON
  # Six fichiers qu'un `chmod a+rX` inconditionnel corrigeait, et que le filtre laissait tels quels :
  # le correctif d'idempotence avait retiré un geste utile en même temps que le geste inutile. La
  # seconde branche ajoute exactement le cas manquant — un `x` existe, mais pas pour tous.
  find "$racine" -type f \( ! -perm -a=r -o \( -perm /111 -a ! -perm -a=x \) \) \
    -exec chmod a+rX {} + || { p_warn "lecture fichiers non posée sous $MEDIA_ROOT"; rc=1; }
  return "$rc"
}

apply() {
  local t src
  # ⚠ TROIS BORNES, PAS UNE — LE RÉSUMÉ MENTAIT DANS LES DEUX SENS AVEC UNE SEULE. `build_doc` est
  # au MILIEU de cette fonction et incrémente le même compteur : une doc reposée sur des médias
  # intacts faisait donc imprimer « médias posés ». Et un `p_warn` n'incrémente rien, si bien qu'un
  # apply où le propriétaire n'a PAS pu être posé annonçait « rien à poser ». On mesure donc les
  # médias À PART de la doc, et on compte les avertissements.
  local _av_tout="$PROV_CHANGED" _av_doc _ap_doc _media_warn=0
  for t in "${MEDIA_TREES[@]}"; do
    src="$(media_src "$t")"
    [[ -d "$src" ]] || { p_fail "source absente : $src — l'arbre livre-t-il encore ses médias ?"; verdict_apply; }
    ensure_dir "$MEDIA_ROOT/$t" "$(media_mode "$t")" "$MEDIA_OWNER" || verdict_apply
    # `cp -a … /.` : le CONTENU, pas le répertoire — sinon un second passage imbrique
    # `avatars/avatars`. Idempotent : on récrit par-dessus, ces fichiers n'ont pas d'état.
    # ⚠ PAS `cp -a "$src/."`, ET C'ÉTAIT LA CAUSE DE LA NON-IDEMPOTENCE. Le `.` désigne le
    # RÉPERTOIRE SOURCE lui-même : `cp -a` recopie donc SES attributs sur la destination — le
    # propriétaire et le mode du checkout, c'est-à-dire un humain et les bits d'un arbre de travail.
    # `ensure_mode` les corrigeait ensuite, comptait une mutation et imprimait un POSÉ. À chaque
    # apply, en boucle, sur un arbre dont le contenu n'avait pas bougé d'un octet.
    # Mesure du 2026-09-08, banc 2005 : `share/avatars` mode=755 own=root:root des deux côtés, et
    # pourtant `perms 0755 root:root /opt/lcars/share/avatars` à chaque passe — le mode était
    # rétabli après avoir été défait, dans la même passe.
    # `-mindepth 1` copie le CONTENU sans jamais toucher aux attributs de la destination.
    #
    # ⚠ `-exec … +` ET PAS `\;` : AVEC `\;`, FIND REND 0 QUOI QU'IL ARRIVE. Mesuré le 2026-09-08 —
    # un `cp` en échec sous `\;` rend rc=0, sous `+` rc=1. Le refus juste en dessous ne se
    # déclenchait donc JAMAIS : un média non copiable sortait « POSÉ », et la machine servait un
    # arbre incomplet en annonçant l'avoir posé. `cp -a -t <dst>` parce que `+` accumule les
    # opérandes à la FIN de la commande.
    #
    # ⚠ ET `-H`, PARCE QU'UNE SOURCE LIÉE COPIAIT ZÉRO FICHIER EN SILENCE. `[[ -d "$src" ]]` est vrai
    # pour un lien vers un répertoire, mais `find <lien> -mindepth 1` ne rend RIEN — find ne suit pas
    # les liens, pas même celui de la ligne de commande (mesuré le 2026-09-08 : sortie vide). Le
    # module posait alors un arbre VIDE, rc 0, « POSÉ ». `-H` suit le point de départ, et lui seul.
    find -H "$src" -mindepth 1 -maxdepth 1 -exec cp -a -t "$MEDIA_ROOT/$t/" {} + \
      || { p_fail "médias non copiables ($src → $MEDIA_ROOT/$t)"; verdict_apply; }
  done
  _av_doc="$PROV_CHANGED"
  build_doc
  _ap_doc="$PROV_CHANGED"

  # ⚠ LE SYMBOLIQUE EST OBLIGATOIRE. `chmod` NUMÉRIQUE ne retire pas le setgid d'un dossier (mesuré :
  # `chmod 0755` sur un dossier setgid laisse `2755`, avec ou sans ACL) — seul `a-s`/`g-s` l'adresse.
  # Sans lui, un checkout fleet (setgid) fait hériter la cible du setgid, et `ensure_dir … 0755`
  # échouait au 2e apply (`2755 ≠ 755`) : le rail cessait d'être idempotent. Le `go=rx` ramène en
  # plus le mask ACL à `r-x`, donc `stat %a` lit bien `755`.
  # `-mindepth 2` : l'arbre PROFOND seulement — les quatre objets que la table declare (share et ses
  # trois sous-arbres) convergent plus bas par `ensure_mode`, au mode de LEUR ligne, et
  # `ensure_mode` efface lui-meme les bits speciaux avant de poser le mode numerique.
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -bR "$MEDIA_ROOT" || { p_warn "ACL héritées non nettoyées sous $MEDIA_ROOT"; _media_warn=1; }
  fi
  # ⚠ CES TROIS GESTES ÉTAIENT INCONDITIONNELS — MAIS UN SEUL DES TROIS CASSAIT L'IDEMPOTENCE, et
  # ma première rédaction les accusait tous les trois. Remesuré le 2026-09-08, primitive par
  # primitive, parce qu'un correctif qui se trompe de cause en réintroduit une autre :
  #
  #     chmod, mode déjà conforme          → ctime INCHANGÉ
  #     chown, propriétaire déjà conforme  → ctime CHANGÉ         ← le coupable des trois
  #     cp -a "$src/." dst/                → ctime de dst CHANGÉ  ← le coupable principal
  #
  # Donc : le `chown -R` inconditionnel touchait bien tout l'arbre à chaque apply (mesure du banc
  # 2005 : `share/avatars` mode=755 own=root:root, ctime 1788879613 → 1788879798), et son filtre
  # est un correctif. Les deux `chmod`, eux, ne changeaient RIEN sur un arbre conforme : leur
  # filtre est un gain de COÛT et une réduction de portée, pas une réparation. Le dire autrement
  # serait s'attribuer une correction qu'on n'a pas faite — le sujet même de ce chantier.
  # Un `chmod`/`chown` ne change jamais le mtime : le défaut était invisible à qui regardait les
  # dates de modification, et c'est pour ça qu'il a vécu si longtemps.
  media_modes "$MEDIA_ROOT" || _media_warn=1
  # ⚠ LE PROPRIETAIRE SUIT LE MEME RAISONNEMENT QUE LE MODE, ET IL MANQUAIT. `cp -a` PRESERVE le
  # proprietaire de la SOURCE : le contenu de `/usr/share/lcars/*` appartenait donc a qui possedait
  # le checkout — un humain, sur un poste. Les deux `find` ci-dessus rattrapaient les modes et
  # jamais les proprietaires, si bien qu'un arbre systeme portait l'identite de l'operateur qui
  # avait lance l'install, et changeait de proprietaire selon QUI deployait. `root:root` est ce que
  # la table declare pour cet arbre ; c'est ici qu'on le tient.
  # ⚠ `-h`, ET CE N'EST PAS UN DÉTAIL DE CONFORT. `chown` SUIT les liens ; `chown -R` ne les suivait
  # pas. En passant au `find … -exec chown`, le geste est devenu une primitive de chown root sur une
  # CIBLE ARBITRAIRE : un lien posé dans l'arbre des médias faisait changer de propriétaire le
  # fichier qu'il désigne, où qu'il soit. Et il ne convergeait jamais — mesuré le 2026-09-08 : sans
  # `-h`, le lien reste à son propriétaire et la cible change ; il est donc resélectionné à CHAQUE
  # passe (2 passes, 1 sélectionné à chaque fois). Avec `-h` : 1 puis 0, et la cible est intacte.
  # C'est aussi ce qui met fin au WARN perpétuel d'un lien cassé — `chown -h` n'a pas besoin de la
  # cible.
  find "$MEDIA_ROOT" \( ! -user root -o ! -group root \) -exec chown -h root:root {} + \
    || { p_warn "propriétaire non posé sous $MEDIA_ROOT — le contenu garde celui de la source (« cp -a » le préserve)"; _media_warn=1; }
  # ⚠ LA TABLE A LE DERNIER MOT SUR CE QU'ELLE DECLARE (lot 15). Les deux `find` posent le mode de
  # l'arbre profond ; les quatre objets que `deploy/system.manifest` nomme convergent ICI, par
  # `ensure_mode`, au mode de leur ligne — et c'est exactement ce que `check` relit.
  local d
  for d in "" "${MEDIA_TREES[@]}" doc; do
    [[ -d "$MEDIA_ROOT${d:+/$d}" ]] || continue
    ensure_mode "$MEDIA_ROOT${d:+/$d}" "$(media_mode "$d")" "$MEDIA_OWNER" || verdict_apply
  done
  # ⚠ ON N'ANNONCE QUE CE QU'ON A FAIT. `PROV_CHANGED` était incrémenté sans condition, et le
  # `p_chg` imprimé à chaque passe : le compteur de changement du rapport comptait donc une
  # mutation sur un arbre strictement identique. C'est le défaut que ce chantier nomme — un rapport
  # qui ment sur ce qu'il a changé — et le module le commettait lui-même.
  local _d_medias=$(( (_av_doc - _av_tout) + (PROV_CHANGED - _ap_doc) ))
  local _d_doc=$(( _ap_doc - _av_doc ))
  if [[ "$_media_warn" -ne 0 ]]; then
    # Un avertissement est un geste qui n'a PAS eu lieu : ni « posé » ni « conforme » ne le dit.
    p_warn "médias posés avec réserve ($MEDIA_ROOT) — un geste ci-dessus n'a pas abouti, l'arbre n'est pas garanti conforme"
  elif [[ "$_d_medias" -ne 0 ]]; then
    p_chg "médias posés ($MEDIA_ROOT : ${MEDIA_TREES[*]})"
  elif [[ "$_d_doc" -ne 0 ]]; then
    p_ok "médias déjà conformes ($MEDIA_ROOT : ${MEDIA_TREES[*]}) — seule la doc a été reposée"
  else
    p_ok "médias et doc déjà conformes ($MEDIA_ROOT : ${MEDIA_TREES[*]} doc) — rien à poser"
  fi
  verdict_apply
}

case "${1:?usage: 44-media.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
