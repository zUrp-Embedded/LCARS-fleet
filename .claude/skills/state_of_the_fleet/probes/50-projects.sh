#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/50-projects.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 50 : les projets, sur disque et sur la forge
#
# LIAISONS PAR CONSTRUCTION. Comme `60-self`, cette sonde ne code aucune attente en dur ; contrairement
# a elle, la declaration ne vit pas dans un fichier de donnees mais dans la SOURCE DU RUNTIME, et on
# l'y LIT :
#
#   `Fleet.Pilot.ProjectOnboard`  — le dual-dir. `<projects>/<nom>` = clone branche `main` ;
#                                   `<work>/<nom>` = depot AUTONOME branche `work/ops`, push `-u`.
#                                   Et : « a dir carrying work ALWAYS has an origin » — l'identite
#                                   d'un projet est son `remote.origin.url`, deux derniers segments.
#   `Fleet.Pilot.WorktreeSync`    — `<projects>/<nom>` est un MIROIR d'`origin/main` : `fetch` +
#                                   `reset --hard`, convergent et idempotent. Consequence exacte :
#                                   une divergence est un DISQUE EN RETARD, jamais une perte — la
#                                   verite est sur la forge.
#   `Fleet.Layout`                — les deux racines, en dur LA-BAS et nulle part ailleurs.
#
# Recopier ces litteraux ici en ferait des copies, et deux copies d'un contrat derivent. On les
# EXTRAIT de la source. Quand la source n'est pas atteignable, on ne devine pas : la declaration est
# `unreachable` et les etats git sont rapportes SANS attente. C'est le motif de faute identifie au
# JOURNAL — fabriquer une source plausible plutot que declarer l'absence — traite a la racine.
#
# L'ASYMETRIE QUI PORTE TOUT LE DIAGNOSTIC, et qu'aucune lecture de `git status` ne donne :
#   cote `main`     — en retard = benin (le miroir se re-derive) ; SALE = destructible (`reset --hard`)
#   cote `work/ops` — en avance = LE SEUL ETAT OU UNE PERTE EST POSSIBLE (rien n'est sur la forge)
# Le meme fait git ne veut pas dire la meme chose des deux cotes. Une sonde qui les traite pareil
# rend un rapport rouge pour du benin et vert pour ce qui se perd.
#
# PERIMETRE (position de starfleet) : les projets sont des OBJETS — ils existent, ils sont a jour,
# leur nom est pris. Jamais leur contenu, jamais l'avancement du travail dedans : ca appartient a
# l'architecte du projet. Le seul role dont le cap-profile monte les deux racines est starfleet ;
# pour tout autre pod, ces racines sont absentes PAR CONSTRUCTION et la sonde le dit sans rougir.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="projects"
PROJ_ROOT="$SOTF_PROJECTS_ROOT"
WORK_ROOT="$SOTF_WORK_ROOT"
CAP="${LCARS_POD_HOME:-$HOME}/.cap-profile.json"

# ── La declaration, extraite de la source du runtime ──────────────────────────────────────────────
# Elle est atteignable exactement quand l'observation l'est : le runtime vit dans un depot pose sous
# `projects_root`, donc un pod qui voit des projets voit aussi la source qui dit ce qu'ils doivent
# etre. Le nom de ce depot n'est PAS ecrit ici — on le trouve par la forme de son arbre.
SRC_ONBOARD="" SRC_LAYOUT=""
DECL_MAIN_BRANCH="" DECL_WORK_BRANCH="" DECL_PROJ_ROOT="" DECL_WORK_ROOT=""

resolve_declarations() {
  local f
  for f in "$PROJ_ROOT"/*/fleet/runtime/lib/fleet/pilot/project_onboard.ex; do
    [[ -r "$f" ]] || continue
    SRC_ONBOARD="$f"
    SRC_LAYOUT="${f%/pilot/project_onboard.ex}/layout.ex"
    break
  done
  [[ -n "$SRC_ONBOARD" ]] || return 1

  # `proj_dir` en fin de motif est LE discriminant : le meme `--branch` apparait sur le chemin
  # d'import du cote work. Sans lui on lirait `work/ops` comme branche du livrable.
  DECL_MAIN_BRANCH="$(sed -n 's/.*"--branch", "\([^"]*\)", url, proj_dir.*/\1/p' "$SRC_ONBOARD" | head -1)"
  # `git init -b <branche>` : la NAISSANCE du cote work, donc sa declaration de reference.
  DECL_WORK_BRANCH="$(sed -n 's/.*"-b", "\([^"]*\)".*/\1/p' "$SRC_ONBOARD" | head -1)"
  [[ -r "$SRC_LAYOUT" ]] || return 0
  DECL_PROJ_ROOT="$(sed -n 's/^ *@projects_root "\([^"]*\)".*/\1/p' "$SRC_LAYOUT" | head -1)"
  DECL_WORK_ROOT="$(sed -n 's/^ *@work_root "\([^"]*\)".*/\1/p' "$SRC_LAYOUT" | head -1)"
}

# S'EMET APRES L'INVENTAIRE, et le verdict en depend. Une declaration manquante n'est un angle mort
# que s'il y a quelque chose a confronter : sur une boite sans projet, crier `unreachable` faisait
# basculer tout le run en AVEUGLE pour une question que personne ne posait. Meme faute que les cinq
# lignes rouges decrivant un daemon jamais demande — et meme correctif : l'absence de CIBLE rend la
# sonde sans objet, pas cassee. Quand l'inventaire est lui-meme aveugle, il le dit deja ; le repeter
# ici compterait deux fois le meme trou.
probe_declaration() {
  local nothing_to_confront=""
  [[ "${#PROJECTS[@]}" -eq 0 ]] && nothing_to_confront=1
  if [[ -z "$SRC_ONBOARD" ]]; then
    emit "projects.declaration" "$PLANE" "$([[ -n "$nothing_to_confront" ]] && echo inactive || echo unreachable)" "local" \
      "ls $PROJ_ROOT/*/fleet/runtime/lib/fleet/pilot/project_onboard.ex" \
      "source du runtime introuvable sous $PROJ_ROOT${nothing_to_confront:+ — et aucun projet a confronter}" \
      "Sans declaration, AUCUNE attente n'est opposable : les etats git eventuels sont rapportes bruts, en 'unknown'. Ne pas lire leur absence de rouge comme une conformite."
    return 1
  fi
  if [[ -z "$DECL_MAIN_BRANCH" || -z "$DECL_WORK_BRANCH" ]]; then
    emit "projects.declaration" "$PLANE" "$([[ -n "$nothing_to_confront" ]] && echo inactive || echo unreachable)" "local" \
      "sed sur $SRC_ONBOARD" \
      "source lisible mais litteraux non extraits (main='${DECL_MAIN_BRANCH:-?}' work='${DECL_WORK_BRANCH:-?}')" \
      "MON extracteur ne reconnait plus la forme de la source, ce qui ne dit rien de la justesse du runtime. Un reformatage suffit a produire cet aveuglement — c'est voulu : echouer aveugle plutot qu'affirmer faux."
    return 1
  fi
  emit "projects.declaration" "$PLANE" "operational" "local" "sed sur $SRC_ONBOARD et $SRC_LAYOUT" \
    "branches declarees : livrable='$DECL_MAIN_BRANCH' work='$DECL_WORK_BRANCH' · racines : '${DECL_PROJ_ROOT:-?}' '${DECL_WORK_ROOT:-?}'" \
    "Lit ce que la source DIT, pas ce que le runtime en service execute : un binaire deploye peut etre plus ancien que l'arbre lu ici."
}

# La sonde sait-elle seulement ou regarder ? Un ecart entre `Fleet.Layout` et la racine que je sonde
# invalide TOUT le reste — je decrirais fidelement un endroit qui n'est pas celui de la fleet.
probe_roots_agree() {
  [[ -n "$DECL_PROJ_ROOT" ]] || return 0
  if [[ "$DECL_PROJ_ROOT" == "$PROJ_ROOT" && "$DECL_WORK_ROOT" == "$WORK_ROOT" ]]; then
    emit "projects.roots_agree" "$PLANE" "operational" "local" "Fleet.Layout vs SOTF_PROJECTS_ROOT" \
      "je sonde les racines que Fleet.Layout declare" \
      "Accord de CHEMINS. Ne prouve pas que le runtime en service utilise ce Fleet.Layout-la."
  else
    emit "projects.roots_agree" "$PLANE" "degraded" "local" "Fleet.Layout vs SOTF_PROJECTS_ROOT" \
      "DIVERGENCE — declare '$DECL_PROJ_ROOT' + '$DECL_WORK_ROOT', je sonde '$PROJ_ROOT' + '$WORK_ROOT'" \
      "Tout ce qui suit decrit fidelement le MAUVAIS endroit. A traiter avant de lire une seule ligne de projet."
  fi
}

# ── Les racines me sont-elles ouvertes ? ──────────────────────────────────────────────────────────
# Trois issues, et les confondre ferait passer un role correctement cloisonne pour une panne :
# lisible / declaree au cap-profile mais illisible / pas declaree du tout (la normale hors starfleet).
mount_declared() {
  [[ -r "$CAP" && -n "${SOTF_HAS_JQ:-}" ]] || return 1
  jq -e --arg p "$1" '(.metadata.mounts // []) | map(.path) | index($p) != null' "$CAP" >/dev/null 2>&1
}

probe_root_access() {
  local id="$1" root="$2"
  if [[ -r "$root" && -x "$root" ]]; then
    emit "projects.$id" "$PLANE" "operational" "local" "ls $root" \
      "racine lisible : $(find "$root" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l) entree(s)" \
      "Lisible n'est pas inscriptible, et la fleet ECRIT ici. Le mode reel du montage n'est pas juge par cette ligne."
    return 0
  fi
  if mount_declared "$root"; then
    emit "projects.$id" "$PLANE" "degraded" "local" "ls $root" \
      "declaree dans metadata.mounts et pourtant illisible" \
      "Le montage promis n'est pas la, OU il est la et les droits le ferment. La sonde ne distingue pas les deux."
  elif [[ -r "$CAP" ]]; then
    emit "projects.$id" "$PLANE" "inactive" "local" "jq '.metadata.mounts' .cap-profile.json" \
      "ce role ne monte pas $root — absence PAR CONSTRUCTION" \
      "Cloisonnement conforme, pas une panne. Seul un role qui monte les deux racines (starfleet) peut rendre l'inventaire complet."
  else
    emit "projects.$id" "$PLANE" "unreachable" "local" "ls $root" \
      "$root inaccessible et aucun cap-profile pour dire si je devrais la voir" \
      "Angle mort double : ni l'observation ni la declaration. Ne prejuge d'aucun projet."
  fi
  return 1
}

# ── L'inventaire — la question de l'user : savoir qu'un nom est PRIS ──────────────────────────────
# « chaque user doit pouvoir voir tous les projets : pas dans le detail si c'est pas son job, mais au
# moins savoir qu'ils existent ». Un nom occupe d'un SEUL cote le reste tout autant : `ProjectOnboard`
# echoue sur `refute_existing` avant meme de joindre la forge.
PROJECTS=()

probe_inventory() {
  local seen name both=0 main_only=0 work_only=0 listing=""
  # `! -name .*` n'est pas un filtre de confort : `Fleet.Layout.sanitize_artifact_name/1` REFUSE le
  # point initial, donc aucun projet ne peut s'appeler ainsi. Sans ce filtre, un `.claude` pose a la
  # racine devenait un projet a huit liaisons, toutes fausses — du bruit qui a l'air d'un constat.
  seen="$( { [[ -r "$PROJ_ROOT" ]] && find "$PROJ_ROOT" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null
             [[ -r "$WORK_ROOT" ]] && find "$WORK_ROOT" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null
           } | sort -u )"
  while read -r name; do
    [[ -z "$name" ]] && continue
    PROJECTS+=("$name")
    if [[ -d "$PROJ_ROOT/$name" && -d "$WORK_ROOT/$name" ]]; then both=$((both+1)); listing="$listing $name"
    elif [[ -d "$PROJ_ROOT/$name" ]]; then main_only=$((main_only+1)); listing="$listing $name(livrable seul)"
    else work_only=$((work_only+1)); listing="$listing $name(work seul)"
    fi
  done <<< "$seen"

  # Zero projet est un etat LEGITIME (fleet neuve) : le compter comme panne rendrait rouge toute
  # boite fraiche, exactement la fausse alarme que la trichotomie existe pour eviter.
  emit "projects.inventory" "$PLANE" "operational" "local" "ls $PROJ_ROOT $WORK_ROOT" \
    "${#PROJECTS[@]} nom(s) occupe(s) — $both complet(s), $main_only livrable seul, $work_only work seul :$listing" \
    "Enumere les NOMS PRIS SUR CE DISQUE. Un depot present sur la forge sans clone local n'y figure pas : avant de creer un projet, la forge tranche, pas cette liste."
}

# ── Observateurs ──────────────────────────────────────────────────────────────────────────────────
# Chacun recoit le nom du projet et rend `verdict|evidence`. Du CODE de lecture, jamais une attente :
# l'attente vient de `$DECL_*`, extraite de la source.

# Identite = `remote.origin.url`, deux derniers segments (regle du runtime lui-meme, `origin_full_name/2`
# : « Base-host agnostic: the last two PATH segments ARE the forge identity »). Comparaison SENSIBLE A
# LA CASSE parce que `Fleet.Layout.project_name/1` ne replie rien — le dossier et le depot portent le
# meme `name` par construction de l'onboard.
origin_url()  { git_ro "$1" config --get remote.origin.url 2>/dev/null; }
origin_name() { local u="${1%/}"; u="${u%.git}"; printf '%s' "${u##*/}"; }

# `.git` est un REPERTOIRE la plupart du temps et un FICHIER le reste du temps (worktree lie,
# submodule) — tester `-d .git` rate le second cas, et c'est exactement ce que fait le cote work de
# LCARS. Pire, interroger git depuis un sous-dossier repond « oui » pour le depot PARENT : sans
# l'egalite avec la racine, `<work>/LCARS/work` passerait pour un projet a part entiere. `-ef`
# compare device+inode, donc un lien symbolique sur le chemin ne fabrique pas un faux negatif.
is_repo() {
  local top
  [[ -d "$1" ]] || return 1
  top="$(git_ro "$1" rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$top" && "$top" -ef "$1" ]]
}

obs_identity() {
  local d="$PROJ_ROOT/$1" url on others
  is_repo "$d" || { echo "inactive|pas de depot cote livrable pour '$1'"; return; }
  url="$(origin_url "$d")"
  if [[ -z "$url" ]]; then
    echo "degraded|aucun remote origin sur $d"; return
  fi
  on="$(origin_name "$url")"
  others="$(git_ro "$d" remote 2>/dev/null | grep -v '^origin$' | tr '\n' ' ')"
  if [[ "$on" == "$1" ]]; then
    echo "operational|origin « $(redact_url "$url") » nomme bien '$1'${others:+ · autres remotes : $others}"
  else
    echo "degraded|DIVERGENCE — dossier '$1', origin nomme '$on' (« $(redact_url "$url") »)${others:+ · autres remotes : $others}"
  fi
}

obs_pair() {
  local m="$PROJ_ROOT/$1" w="$WORK_ROOT/$1" hm=0 hw=0
  is_repo "$m" && hm=1
  is_repo "$w" && hw=1
  case "$hm$hw" in
    11) echo "operational|dual-dir complet : livrable et work/ops sont deux depots" ;;
    10) echo "degraded|cote work ABSENT ($w) — le dual-dir declare les deux" ;;
    01) echo "degraded|cote livrable ABSENT ($m) — le dual-dir declare les deux" ;;
    *)  echo "unknown|nom occupe des deux cotes mais aucun depot git : residu, ou dossier tiers" ;;
  esac
}

obs_branch() {
  local d="$PROJ_ROOT/$1" b
  is_repo "$d" || { echo "inactive|pas de depot cote livrable"; return; }
  b="$(git_ro "$d" symbolic-ref --short HEAD 2>/dev/null)"
  [[ -n "$b" ]] || { echo "degraded|HEAD detache ($(git_ro "$d" rev-parse --short HEAD 2>/dev/null)) — aucune branche a confronter"; return; }
  [[ "$b" == "$DECL_MAIN_BRANCH" ]] \
    && echo "operational|sur '$b', conforme a la declaration" \
    || echo "degraded|DIVERGENCE — declare '$DECL_MAIN_BRANCH', le clone est sur '$b'"
}

# LE miroir. `reset --hard origin/main` re-derive l'etat COMPLET : un retard se soigne tout seul au
# prochain merge. C'est pourquoi l'ecart est un constat de retard, pas une alerte de perte.
obs_mirror() {
  local d="$PROJ_ROOT/$1" ref="refs/remotes/origin/$DECL_MAIN_BRANCH" counts ahead behind
  is_repo "$d" || { echo "inactive|pas de depot cote livrable"; return; }
  git_ro "$d" rev-parse --verify -q "$ref" >/dev/null 2>&1 \
    || { echo "unknown|aucune ref de suivi $ref : jamais fetch depuis ce clone, ou origin renomme"; return; }
  counts="$(git_ro "$d" rev-list --left-right --count "HEAD...$ref" 2>/dev/null)"
  [[ -n "$counts" ]] || { echo "unreachable|rev-list muet sur $d"; return; }
  ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
  if [[ "$ahead" == 0 && "$behind" == 0 ]]; then
    echo "operational|aligne sur $ref ($(git_ro "$d" rev-parse --short HEAD 2>/dev/null))"
  else
    echo "degraded|$ahead commit(s) en avance, $behind en retard sur $ref"
  fi
}

# Sale cote livrable : `WorktreeSync` ECRASE. Ce n'est pas « du travail non commite », c'est du
# travail CONDAMNE — et la difference doit sortir du rapport, pas de la tete du lecteur.
obs_clean() {
  local d="$PROJ_ROOT/$1" n
  is_repo "$d" || { echo "inactive|pas de depot cote livrable"; return; }
  n="$(git_ro "$d" status --porcelain 2>/dev/null | wc -l)"
  [[ "$n" == 0 ]] \
    && echo "operational|arbre propre" \
    || echo "degraded|$n entree(s) non commitees dans un arbre que WorktreeSync ecrase au prochain merge"
}

obs_work_branch() {
  local d="$WORK_ROOT/$1" b
  is_repo "$d" || { echo "inactive|pas de depot cote work"; return; }
  b="$(git_ro "$d" symbolic-ref --short HEAD 2>/dev/null)"
  [[ -n "$b" ]] || { echo "degraded|HEAD detache cote work — aucune branche a confronter"; return; }
  [[ "$b" == "$DECL_WORK_BRANCH" ]] \
    && echo "operational|sur '$b', conforme a la declaration" \
    || echo "degraded|DIVERGENCE — declare '$DECL_WORK_BRANCH', le depot est sur '$b'"
}

# L'unique etat de cette sonde ou quelque chose peut se PERDRE. Le cote work est un depot autonome :
# rien ne le re-derive, personne ne le rejoue. Ce qui n'est pas pousse n'existe qu'ici.
obs_work_unpushed() {
  local d="$WORK_ROOT/$1" ref="refs/remotes/origin/$DECL_WORK_BRANCH" counts ahead dirty
  is_repo "$d" || { echo "inactive|pas de depot cote work"; return; }
  dirty="$(git_ro "$d" status --porcelain 2>/dev/null | wc -l)"
  git_ro "$d" rev-parse --verify -q "$ref" >/dev/null 2>&1 \
    || { echo "unknown|aucune ref de suivi $ref : jamais pousse, ou jamais fetch — dans les deux cas je ne sais pas ce qui manque a la forge (+$dirty fichier(s) non commite(s))"; return; }
  counts="$(git_ro "$d" rev-list --left-right --count "HEAD...$ref" 2>/dev/null)"
  ahead="${counts%%[[:space:]]*}"
  if [[ "${ahead:-0}" -gt 0 ]]; then
    echo "degraded|$ahead commit(s) ne vivent que sur ce disque (+$dirty fichier(s) non commite(s))"
  else
    echo "operational|rien d'inedit face a $ref (+$dirty fichier(s) non commite(s), etat de travail normal ici)"
  fi
}

# ── La forge, adresse DECLAREE PAR LE DEPOT ───────────────────────────────────────────────────────
# On ne devine plus l'org (faute du JOURNAL, cf. `FORGE_ORG` invente) : `remote.origin.url` porte
# l'org ET l'hote, projet par projet. Et cette sonde ferme la limite que `mirror` declare : elle
# compare la ref de suivi LOCALE au sha que la forge annonce, donc elle dit si `mirror` a raisonne
# sur une ref perimee.
obs_forge() {
  local d="$PROJ_ROOT/$1" url base owner name u remote_sha local_ref
  is_repo "$d" || d="$WORK_ROOT/$1"
  is_repo "$d" || { echo "inactive|aucun depot local pour '$1'"; return; }
  url="$(origin_url "$d")"
  [[ -n "$url" ]] || { echo "inactive|aucun origin : rien a interroger"; return; }
  if [[ "$url" != http://* && "$url" != https://* ]]; then
    echo "unknown|origin « $(redact_url "$url") » n'est pas une adresse http : l'etat sur la forge n'est pas interrogeable sans deviner un schema et un port"
    return
  fi
  # `anon_url` AVANT tout decoupage : un origin credente rendrait cette lecture authentifiee en
  # silence, et tout ce que la liaison declare sur l'anonymat deviendrait faux.
  base="$(anon_url "${url%.git}")"; name="${base##*/}"; base="${base%/*}"; owner="${base##*/}"; base="${base%/*}"
  u="$base/api/v1/repos/$owner/$name/branches/$DECL_MAIN_BRANCH"
  http_probe "$u" 6 || { echo "unreachable|curl absent : aveugle sur la forge"; return; }
  case "$SOTF_HTTP_CODE" in
    2*)
      # Sans jq, le sha ne serait pas « introuvable dans la reponse » — il serait illisible PAR MOI.
      # Confondre les deux ferait accuser la forge d'un defaut de forme qui est un trou d'outillage.
      [[ -n "${SOTF_HAS_JQ:-}" ]] || { echo "unknown|HTTP $SOTF_HTTP_CODE mais sans jq je ne lis pas le sha annonce"; return; }
      remote_sha="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.commit.id // ""' 2>/dev/null)"
      local_ref="$(git_ro "$d" rev-parse "refs/remotes/origin/$DECL_MAIN_BRANCH" 2>/dev/null)"
      if [[ -z "$remote_sha" ]]; then
        echo "unknown|HTTP $SOTF_HTTP_CODE mais sha introuvable dans la reponse"
      elif [[ "$remote_sha" == "$local_ref" ]]; then
        echo "operational|forge et ref de suivi locale sur ${remote_sha:0:9} — la comparaison de miroir portait sur une ref A JOUR"
      else
        echo "degraded|forge sur ${remote_sha:0:9}, ref de suivi locale sur ${local_ref:0:9} — le clone n'a pas fetch : le verdict de miroir ci-dessus est PERIME"
      fi ;;
    404) echo "unknown|HTTP 404 en anonyme sur $owner/$name : depot absent OU prive — un token tranche, pas cette sonde" ;;
    000) echo "degraded|forge $base injoignable ($(trim "$SOTF_HTTP_BODY" 120))" ;;
    *)   echo "unknown|HTTP $SOTF_HTTP_CODE sur $u" ;;
  esac
}

# ── Le catalogue de liaisons ──────────────────────────────────────────────────────────────────────
# suffixe ¤ ou vit la DECLARATION (citation, verifiable a la main) ¤ observateur ¤ ce qu'un ecart ne prouve pas
BINDINGS=(
"pair¤ProjectOnboard @moduledoc — dual-dir : deux depots locaux pour un depot forge¤obs_pair¤Presence des deux depots seulement. Ne dit pas qu'ils parlent du MEME projet : c'est la liaison 'identity' qui le confronte."
"identity¤ProjectOnboard.origin_full_name/2 — les deux derniers segments de remote.origin.url SONT l'identite forge¤obs_identity¤Compare un NOM a un NOM. Un origin juste ne prouve pas que le depot distant existe, ni qu'il est le bon contenu."
"branch¤ProjectOnboard — git clone --branch <livrable> vers proj_dir¤obs_branch¤Nomme la branche courante. Ne dit pas qui l'a changee ni si un travail y est en cours."
"mirror¤WorktreeSync.align/1 — fetch puis reset --hard origin/<livrable>, convergent et idempotent¤obs_mirror¤Compare a la DERNIERE ref de suivi connue localement : la sonde ne fetch PAS (ecriture dans le depot + credentials). Un origin perime fait passer un clone en retard pour aligne — la liaison 'forge' est la pour lever ce doute. Et un ecart reste un disque en retard : la verite est sur la forge, jamais une perte."
"clean¤WorktreeSync @moduledoc — « the worktree is a read-only showcase », reset --hard n'ecrase rien d'utile¤obs_clean¤Compte des entrees, ne les juge pas : artefacts de build et travail humain sont indiscernables ici. Dit qu'elles seront ECRASEES, pas qu'elles ont de la valeur."
"work_branch¤ProjectOnboard — git init -b <work> pour le depot autonome¤obs_work_branch¤Branche seulement. Ne dit rien du contenu de work/ops ni de sa fraicheur face au travail reel."
"work_unpushed¤ProjectOnboard — push -u <work> ; doctrine D1 : la verite durable vit sur la forge¤obs_work_unpushed¤Compte les commits absents de la ref de suivi LOCALE : ne voit pas un push fait depuis un autre clone, et ne voit pas le non-commite (il n'est pas dans git). Le compteur de fichiers sales est indicatif, pas un verdict."
"forge¤remote.origin.url du depot lui-meme — l'adresse est declaree, plus jamais devinee¤obs_forge¤Lecture ANONYME : un 404 ne separe pas 'absent' de 'invisible sans jeton'. Interroge la branche livrable seule — l'etat de work/ops sur la forge n'est pas lu ici."
)

run_project_bindings() {
  local p rec suffix decl fn cannot out verdict evidence
  for p in "${PROJECTS[@]}"; do
    for rec in "${BINDINGS[@]}"; do
      IFS='¤' read -r suffix decl fn cannot <<< "$rec"
      out="$($fn "$p")"
      verdict="${out%%|*}"; evidence="${out#*|}"
      emit "projects.$p.$suffix" "$PLANE" "$verdict" \
        "$([[ "$suffix" == forge ]] && echo reseau || echo local)" \
        "declare: $decl" "$evidence" "$cannot"
    done
  done
}

# Sans declaration, on rapporte quand meme l'observable — mais en `unknown`, jamais en vert. Un etat
# git sans attente opposable n'est pas une conformite : c'est une photo.
run_projects_unbound() {
  local p b
  for p in "${PROJECTS[@]}"; do
    b="$(git_ro "$PROJ_ROOT/$p" symbolic-ref --short HEAD 2>/dev/null)"
    emit "projects.$p.etat" "$PLANE" "unknown" "local" "git -C $PROJ_ROOT/$p symbolic-ref HEAD ; status --porcelain" \
      "branche '${b:-?}' · $(git_ro "$PROJ_ROOT/$p" status --porcelain 2>/dev/null | wc -l) entree(s) sale(s) · work : $(is_repo "$WORK_ROOT/$p" && echo present || echo absent)" \
      "Observation SANS declaration a confronter (la source du runtime n'est pas lisible d'ici). Ne conclut ni conformite ni ecart."
  done
}

# ── Le perimetre — ce que l'onboarding declare et qu'AUCUNE liaison ne regarde ─────────────────────
# Jumeau de `self.coverage` : un champ non regarde n'est pas conforme, il est hors de vue. Le dire
# est un aveu de perimetre, et c'est la seule facon qu'un lecteur ait de savoir ou ne pas se fier.
probe_perimeter() {
  local covered
  covered="$(printf '%s\n' "${BINDINGS[@]}" | awk -F'¤' '{print $1}' | tr '\n' ' ')"
  emit "projects.perimeter" "$PLANE" "unknown" "local" "les liaisons declarees dans cette sonde" \
    "${#PROJECTS[@]} projet(s) x $(printf '%s\n' "${BINDINGS[@]}" | wc -l) liaisons : $covered" \
    "NON confronte, bien que declare par ProjectOnboard : le contenu du scaffold (README, .gitignore, docs/spec.md, backlog.md, plans/), la protection de branche posee sur la forge, et l'architecte per-projet spawne a l'onboarding. Ces trois zones sont declarees et non regardees."
}

# ── Runner ────────────────────────────────────────────────────────────────────────────────────────
sotf_init
# Sans git, TOUTE liaison de cette sonde rendrait « pas de depot » sur des projets parfaitement
# sains : le silence de l'instrument se lirait comme un constat d'absence. C'est le mensonge exact
# que la distinction unreachable/degraded existe pour interdire — donc on s'arrete ici.
have git || {
  emit "projects.instrument" "$PLANE" "unreachable" "local" "command -v git" \
    "git absent : aucune liaison de ce plan n'est mesurable" \
    "Angle mort TOTAL sur les projets. N'affirme ni qu'ils existent, ni qu'ils sont a jour, ni qu'il n'y en a pas."
  exit "$(sotf_exit_code)"
}
resolve_declarations || true

# L'ordre EST le raisonnement : ou puis-je regarder → qu'y a-t-il → que devrait-ce etre → confrontation.
# La declaration s'evalue apres l'inventaire parce que sa PERTINENCE en depend.
#
# Les deux racines sont deux questions : starfleet monte les deux, un autre role n'en monte aucune,
# et un montage a moitie fait est precisement le genre d'etat qu'on veut voir nomme.
probe_root_access "root_projects" "$PROJ_ROOT"
probe_root_access "root_work" "$WORK_ROOT"

if [[ -r "$PROJ_ROOT" || -r "$WORK_ROOT" ]]; then
  probe_inventory
else
  emit "projects.inventory" "$PLANE" "unreachable" "local" "ls $PROJ_ROOT $WORK_ROOT" \
    "aucune des deux racines n'est lisible" \
    "Aveugle sur les projets : n'affirme ni qu'il y en a, ni qu'il n'y en a pas. Un nom peut etre pris sans que je le voie."
fi

HAVE_DECL=0
probe_declaration && HAVE_DECL=1
probe_roots_agree

if [[ "${#PROJECTS[@]}" -gt 0 ]]; then
  if [[ "$HAVE_DECL" == 1 ]]; then run_project_bindings; probe_perimeter; else run_projects_unbound; fi
fi
exit "$(sotf_exit_code)"
