#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/sotf.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — les deux entrees du skill : `report` et `diag`
#
# DEUX QUESTIONS, PAS UNE. Elles ont l'air voisines et elles ne le sont pas :
#
#   report   « qu'est-ce qui est vrai en ce moment ? » — toutes les sondes, un tableau, un horodatage.
#            Se lit, s'archive, se compare a celui d'hier.
#   diag     « qu'est-ce que je peux ENTREPRENDRE ? » — des verdicts de CAPACITE, pour que starfleet
#            n'aille pas depenser un spawn sur un geste dont un maillon est mort. C'est la demande
#            d'origine : « savoir ce qui est casse pour pas s'acharner a poller un truc qui ne
#            repondra jamais ».
#
# ON RAPPORTE, ON NE REPARE PAS. Ni ici, ni ailleurs dans ce skill. Le chemin pour reparer est un
# autre chantier, et un outil qui repare pendant qu'il mesure ne mesure plus rien.
#
# LA NUANCE QUI PORTE TOUT `diag` : un outil `mcp__fleet__*` n'est PAS execute par moi. Je l'appelle,
# la fleet l'execute — avec ses credentials, ses montages, son reseau. Mes sondes, elles, mesurent MON
# poste d'observation. Donc une chaine de capacite distingue deux natures de maillon :
#
#   ! bloquant   ce que je constate d'autorite : mon canal MCP, et ce que la fleet publie d'elle-meme
#                (`readiness/deep`). Rouge → ne pas entreprendre.
#   ? indicatif  ce que je mesure DEPUIS MA PLACE et qui ne prouve rien du geste de la fleet (la forge
#                vue du pod, mes racines montees). Rouge → je ne peux pas confirmer, jamais « c'est
#                casse », et surtout jamais un vert.
#
# Confondre les deux fabriquerait le pire rapport possible : `forge.credentials` est `inactive` dans
# TOUT pod par design, et l'inscrire en bloquant declarerait `create_project` mort en permanence sur
# une fleet parfaitement capable de le faire.

set -uo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$SKILL_DIR/probes"
# shellcheck source=probes/lib.sh
. "$P/lib.sh"

PLANE="capacites"
CAP="${LCARS_POD_HOME:-$HOME}/.cap-profile.json"

# ── Les chaines de capacite ───────────────────────────────────────────────────────────────────────
# capacite ¤ maillons (!bloquant / ?indicatif) ¤ d'ou vient la chaine ¤ ce qu'un vert ne promet pas
#
# Les maillons sont des ids de sonde, stables par contrat. Un id qui n'existe plus se voit : la sonde
# a tourne, le maillon est absent du flux, et la capacite passe `unreachable` en le nommant. C'est le
# meme motif que `pods.port_guard` — une connaissance recopiee porte son detecteur de derive.
CHAINS=(
"list_workflow_cards¤!instruments.mcp_socket,!fleet.health,!fleet.subsystem.mcp.pod_facing¤Lecture pure du catalogue de cartes a travers MCP : aucun ecrit, aucune forge.¤Le canal repond et la fleet se declare saine. Ne promet pas que le catalogue est PEUPLE, ni que les cartes qu'il contient sont valides."
"create_project¤!instruments.mcp_socket,!fleet.health,!fleet.subsystem.mcp.pod_facing,!fleet.subsystem.spawn.dispatch,?forge.reachable,?projects.root_projects,?projects.root_work,?fleet.subsystem.launch.backend,?fleet.subsystem.pilot.step¤ProjectOnboard : create_repo sur la forge (fail-loud si le depot existe), clone, scaffold, dual-dir work/ops, puis spawn de l'architecte per-projet.¤Rien du COTE FORGE : la fleet cree le depot avec SES credentials, que je ne vois pas et ne dois pas voir. Un vert ici veut dire « le geste est appelable », pas « il aboutira ». L'echec du spawn de l'architecte n'annule pas le projet (ProjectOnboard le rapporte sans le defaire), d'ou launch.backend en indicatif."
"import_project¤!instruments.mcp_socket,!fleet.health,!fleet.subsystem.mcp.pod_facing,!fleet.subsystem.spawn.dispatch,?forge.reachable,?projects.root_projects,?projects.root_work,?fleet.subsystem.pilot.step¤Jumeau de create_project : ADOPTE un depot existant au lieu de le creer. Memes ecritures disque, meme dual-dir.¤Ne dit rien du depot a adopter : ni qu'il existe, ni qu'il est visible par la fleet, ni qu'il a une branche main clonable."
"open_project¤!instruments.mcp_socket,!fleet.health,!fleet.subsystem.mcp.pod_facing,!fleet.subsystem.spawn.dispatch,!fleet.subsystem.launch.backend,?projects.root_projects,?fleet.subsystem.pilot.step¤Troisieme verbe : RELANCE un projet deja sur la machine — pas de forge, mais un vrai spawn, donc le backend de lancement est bloquant ici alors qu'il est indicatif ailleurs.¤Ne verifie pas que le projet vise existe : la sonde 50 enumere les noms pris, c'est elle qu'on lit AVANT de nommer une cible."
)

# Prefixe d'id → sonde qui le produit. Mecanique, pas une table a maintenir : le plan EST le prefixe.
script_for_plane() {
  case "$1" in
    instruments) echo "$P/10-instruments.sh" ;; fleet) echo "$P/20-fleet.sh" ;;
    pods)        echo "$P/30-pods.sh" ;;        forge) echo "$P/40-forge.sh" ;;
    projects)    echo "$P/50-projects.sh" ;;    self)  echo "$P/60-self.sh" ;;
    *) return 1 ;;
  esac
}
ALL_SCRIPTS=("$P/10-instruments.sh" "$P/20-fleet.sh" "$P/30-pods.sh" "$P/40-forge.sh" "$P/50-projects.sh" "$P/60-self.sh")

chain_of()   { local r; for r in "${CHAINS[@]}"; do [[ "${r%%¤*}" == "$1" ]] && { printf '%s' "$r"; return; }; done; return 1; }
chain_names() { printf '%s\n' "${CHAINS[@]}" | awk -F'¤' '{print $1}'; }

# ── Lecture du flux accumule ──────────────────────────────────────────────────────────────────────
# `verdict_of` rend le verdict d'un maillon, ou la chaine vide s'il n'a pas ete emis. La distinction
# « pas emis parce que la sonde n'a pas tourne » et « pas emis alors qu'elle a tourne » se fait par
# `plane_ran`, et elle compte : la premiere est un court-circuit voulu, la seconde est ma derive.
JSONL=""
verdict_of() { printf '%s\n' "$JSONL" | jq -r --arg p "$1" 'select(.probe==$p) | .verdict' 2>/dev/null | head -1; }
evidence_of() { printf '%s\n' "$JSONL" | jq -r --arg p "$1" 'select(.probe==$p) | .evidence' 2>/dev/null | head -1; }
RAN_PLANES=" "
plane_ran() { [[ "$RAN_PLANES" == *" $1 "* ]]; }

run_probe_script() {
  local s="$1" plane out
  plane="$(basename "$s")"; plane="${plane#*-}"; plane="${plane%.sh}"
  case "$plane" in instruments|fleet|pods|forge|projects|self) ;; *) plane="" ;; esac
  out="$("$s" 2>/dev/null)"
  JSONL="${JSONL:+$JSONL$'\n'}$out"
  [[ -n "$plane" ]] && RAN_PLANES="$RAN_PLANES$plane "
}

# ── Le verdict d'une capacite ─────────────────────────────────────────────────────────────────────
# Ordre de preseance, et il repond a « que dois-je faire », pas a « quelle est la couleur moyenne » :
#   degraded     un maillon est casse, et il est nommable                  → n'entreprends pas
#   unreachable  un maillon n'a pas pu etre mesure, ou n'existe plus       → tu serais aveugle
#   inactive     un maillon n'a rien a atteindre (aucune fleet, p. ex.)    → il n'y a pas de cible
#   unknown      tout ce qui bloque est vert, mais un indicatif ne l'est pas → appelable, non confirme
#   operational  tout est vert                                             → vas-y
# `degraded` passe devant `unreachable` parce qu'un fait constate est plus actionnable qu'un trou ;
# `inactive` passe derriere les deux parce qu'une absence legitime n'a pas a masquer une panne.
capability_verdict() {
  local rec="$1" links kind id v
  IFS='¤' read -r _ links _ _ <<< "$rec"
  local bad_deg="" bad_unr="" bad_inact="" bad_advice="" missing=""
  for id in ${links//,/ }; do
    kind="${id:0:1}"; id="${id:1}"
    v="$(verdict_of "$id")"
    if [[ -z "$v" ]]; then
      # Emis par personne alors que sa sonde a tourne : la chaine nomme un maillon qui n'existe plus.
      plane_ran "${id%%.*}" && missing="$missing $id"
      continue
    fi
    case "$kind$v" in
      '!degraded')    bad_deg="$bad_deg $id" ;;
      '!unreachable') bad_unr="$bad_unr $id" ;;
      '!inactive')    bad_inact="$bad_inact $id" ;;
      '!unknown')     bad_advice="$bad_advice $id(ambigu)" ;;
      '?'operational|'?'inactive) : ;;
      '?'*)           bad_advice="$bad_advice $id($v)" ;;
    esac
  done
  # Le maillon bloquant est CITE avec son propre constat. Une ligne de capacite qui se contente de
  # nommer un id oblige le lecteur a redescendre dans le tableau ; or `diag` existe pour etre lu par
  # quelqu'un qui est sur le point d'agir, pas pour l'envoyer chercher.
  local why; why() { local l="${1# }"; l="${l%% *}"; local e; e="$(evidence_of "$l")"; printf '%s' "${e:+ — « $(trim "$e" 120) »}"; }
  if   [[ -n "$missing"    ]]; then echo "unreachable|maillon(s) inconnu(s) du flux :$missing — la chaine designe des sondes qui n'existent plus"
  elif [[ -n "$bad_deg"    ]]; then echo "degraded|bloque par :$bad_deg$(why "$bad_deg")"
  elif [[ -n "$bad_unr"    ]]; then echo "unreachable|non mesurable :$bad_unr$(why "$bad_unr")"
  elif [[ -n "$bad_inact"  ]]; then echo "inactive|sans objet :$bad_inact$(why "$bad_inact")"
  elif [[ -n "$bad_advice" ]]; then echo "unknown|appelable, mais non confirmable d'ici :$bad_advice"
  else echo "operational|tous les maillons bloquants sont verts"; fi
}

# ── Le perimetre declare — les capacites ne sont pas MON idee de ce que fait ce pod ────────────────
# `spec.scope.allowedTools` du cap-profile est la seule liste qui fasse foi. La confronter au
# catalogue de chaines repond aux deux questions dans les deux sens : un outil sans chaine (je ne sais
# pas de quoi il depend) et une chaine hors perimetre (je decris un geste que ce pod ne peut pas
# poser). Sans cap-profile, on evalue tout et on le DIT.
scoped_tools() {
  [[ -r "$CAP" && -n "${SOTF_HAS_JQ:-}" ]] || return 1
  jq -r '(.spec.scope.allowedTools // [])[] | select(startswith("mcp__fleet__")) | sub("^mcp__fleet__";"")' \
    "$CAP" 2>/dev/null
}

emit_scope_confrontation() {
  local scope name
  scope="$(scoped_tools)" || {
    emit "capacites.perimetre" "$PLANE" "unknown" "local" "jq '.spec.scope.allowedTools' .cap-profile.json" \
      "aucun cap-profile lisible ($CAP) : toutes les chaines connues sont evaluees" \
      "Les capacites listees ne sont pas forcement dans le perimetre du pod qui lit ce rapport. Hors d'un pod, ce fichier n'existe pas et cette ligne est normale."
    return
  }
  local no_chain="" extra=""
  while read -r name; do
    [[ -z "$name" ]] && continue
    chain_of "$name" >/dev/null || no_chain="$no_chain $name"
  done <<< "$scope"
  while read -r name; do
    [[ -z "$name" ]] && continue
    grep -qx -- "$name" <<< "$scope" || extra="$extra $name"
  done < <(chain_names)

  if [[ -z "$no_chain" && -z "$extra" ]]; then
    emit "capacites.perimetre" "$PLANE" "operational" "local" "cap-profile vs catalogue de chaines" \
      "les $(printf '%s\n' "$scope" | grep -c . ) outils fleet du perimetre ont chacun leur chaine" \
      "Accord de NOMS. Ne dit pas que la chaine decrit correctement ce dont l'outil depend — ca, seule une panne reelle le corrige."
  else
    emit "capacites.perimetre" "$PLANE" "unknown" "local" "cap-profile vs catalogue de chaines" \
      "sans chaine declaree :${no_chain:- aucun} · chaines hors perimetre :${extra:- aucune}" \
      "Un outil sans chaine n'est PAS reput sain : je ne sais simplement pas de quoi il depend, donc je ne peux rien dire avant de l'appeler."
  fi
}

# ── diag ──────────────────────────────────────────────────────────────────────────────────────────
# « descend une chaine jusqu'au premier maillon casse » : on lance les sondes dans l'ordre et on
# s'arrete des que TOUTE capacite demandee est deja tranchee negativement. Interet reel, pas de la
# coquetterie : les sondes aval d'un maillon mort ne rapportent que des consequences, et une page de
# consequences noie la cause.
do_diag() {
  local wanted=("$@") rec name links id planes="" plane s short=""
  [[ "${#wanted[@]}" -eq 0 ]] && mapfile -t wanted < <(chain_names)

  local unknown_targets=""
  for name in "${wanted[@]}"; do
    rec="$(chain_of "$name")" || { unknown_targets="$unknown_targets $name"; continue; }
    IFS='¤' read -r _ links _ _ <<< "$rec"
    for id in ${links//,/ }; do
      plane="${id:1}"; plane="${plane%%.*}"
      [[ "$planes" == *" $plane "* ]] || planes="$planes $plane "
    done
  done

  # `instruments` d'abord et TOUJOURS : mesurer mes angles morts avant de mesurer quoi que ce soit
  # d'autre est la seule facon de savoir ce que vaut le reste du rapport.
  for s in "${ALL_SCRIPTS[@]}"; do
    plane="$(basename "$s")"; plane="${plane#*-}"; plane="${plane%.sh}"
    [[ "$plane" == instruments || "$planes" == *" $plane "* ]] || continue
    run_probe_script "$s"
    local all_blocked=1 v
    for name in "${wanted[@]}"; do
      rec="$(chain_of "$name")" || continue
      v="$(capability_verdict "$rec")"; v="${v%%|*}"
      [[ "$v" == degraded || "$v" == inactive ]] || { all_blocked=0; break; }
    done
    if [[ "$all_blocked" -eq 1 ]]; then short="$(basename "$s")"; break; fi
  done

  # TOUT ce qui suit part dans le flux, pas sur stdout. Les lignes de capacite sont des sondes comme
  # les autres : hors du JSONL elles echappent au rendu, au comptage et au code de sortie — soit
  # exactement les trois choses qui font qu'un rapport engage quelqu'un.
  JSONL="${JSONL:+$JSONL$'\n'}$(
    for name in "${wanted[@]}"; do
      rec="$(chain_of "$name")" || continue
      local out cannot origin
      IFS='¤' read -r _ _ origin cannot <<< "$rec"
      out="$(capability_verdict "$rec")"
      emit "capacites.$name" "$PLANE" "${out%%|*}" "local" "chaine : $origin" "${out#*|}" "$cannot"
    done
    for name in $unknown_targets; do
      emit "capacites.$name" "$PLANE" "unreachable" "local" "catalogue de chaines" \
        "capacite inconnue de ce toolkit" \
        "Je n'ai aucune chaine pour ce nom : ni sa sante ni son existence ne sont affirmees ici."
    done
    emit_scope_confrontation
    [[ -n "$short" ]] && emit "capacites.court_circuit" "$PLANE" "inactive" "local" "arret apres $short" \
      "sondes aval non lancees : toute capacite demandee etait deja tranchee" \
      "Les plans non sondes ne sont ni sains ni malades — ils ne sont pas mesures. Un 'report' complet les couvre."
  )"
}

# ── report ────────────────────────────────────────────────────────────────────────────────────────
do_report() { local s; for s in "${ALL_SCRIPTS[@]}"; do run_probe_script "$s"; done; }

# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
usage:
  sotf.sh report [--md] [--out FICHIER.md] [--full] [--raw]
  sotf.sh diag [capacite ...] [--md] [--out FICHIER.md] [--full] [--raw]

  report  toutes les sondes, tous les plans — l'etat, a un instant date.
  diag    des verdicts de CAPACITE : ce qui est entreprenable, et par quel maillon ca bloque.
          Sans argument : toutes les capacites connues.
  --raw   le JSONL brut, sans rendu (c'est lui la source de verite).

capacites connues : $(chain_names | tr '\n' ' ')
EOF
}

#
# Le code se derive du FLUX, jamais des compteurs de `lib.sh` : les sondes tournent dans des
# processus separes, donc leurs `SOTF_DRIFT` n'arrivent jamais ici. `--raw` rendait 0 sur un run
# aveugle — un succes ambigu, exactement ce que le contrat de sortie existe pour interdire.
jsonl_exit_code() {
  local unr deg
  unr="$(printf '%s\n' "$JSONL" | grep -c '"verdict":"unreachable"' || true)"
  deg="$(printf '%s\n' "$JSONL" | grep -c '"verdict":"degraded"' || true)"
  if [[ "$unr" -gt 0 ]]; then echo 2; elif [[ "$deg" -gt 0 ]]; then echo 1; else echo 0; fi
}

# Garde de source (meme motif que `publish-transform.sh`) : sourcer ce fichier donne acces aux
# fonctions SANS declencher un run. Sans elle, les tests du raisonnement de capacite devraient passer
# par la CLI et donc par de vraies sondes — ils mesureraient la machine au lieu de la logique.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

CMD="${1:-}"; shift 2>/dev/null || true
RENDER_ARGS=() TARGETS=() RAW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --md|--full) RENDER_ARGS+=("$1") ;;
    --out) RENDER_ARGS+=("$1" "${2:-}"); shift ;;
    --raw) RAW=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "sotf: option inconnue : $1" >&2; usage; exit 2 ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done

sotf_init
case "$CMD" in
  report) [[ "${#TARGETS[@]}" -eq 0 ]] || { echo "sotf: 'report' ne prend pas de cible" >&2; exit 2; }
          do_report ;;
  diag)   do_diag "${TARGETS[@]+"${TARGETS[@]}"}" ;;
  ''|-h|--help) usage; exit 0 ;;
  *) echo "sotf: commande inconnue : $CMD" >&2; usage; exit 2 ;;
esac

# Le JSONL reste la source de verite ; le rendu ne fait que le presenter. Son code de sortie est le
# verdict global (0 conforme / 1 drift / 2 aveugle) et c'est LUI qu'on propage : un `report` qui
# rendrait 0 sur un plan aveugle serait le mensonge que tout ce skill existe pour empecher.
[[ -n "$JSONL" ]] || { echo "sotf: aucune sonde n'a rien emis — c'est EN SOI le premier constat" >&2; exit 2; }
if [[ "$RAW" -eq 1 ]]; then printf '%s\n' "$JSONL"; exit "$(jsonl_exit_code)"; fi
printf '%s\n' "$JSONL" | "$P/render.sh" "${RENDER_ARGS[@]+"${RENDER_ARGS[@]}"}"
