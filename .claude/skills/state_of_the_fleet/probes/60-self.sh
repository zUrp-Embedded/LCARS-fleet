#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/60-self.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 60 : le pod se confronte a sa propre declaration
#
# LA SEULE SONDE OU L'AGENT EST A LA FOIS L'INSTRUMENT ET LE SUJET.
#
# Et la seule batie sur des LIAISONS plutot que sur des checks ecrits a la main. La difference n'est
# pas cosmetique : un check code en dur porte une attente que quelqu'un a tapee, donc une COPIE
# d'une verite qui vit ailleurs — et deux copies d'un contrat derivent. Une liaison ne copie rien :
# elle dit ou lire la declaration, ou lire l'observation, et laisse la confrontation etre le verdict.
#
# Le catalogue, c'est donc le `.cap-profile.json` du pod lui-meme. Il est ECRIT PAR LE RUNTIME au
# spawn (`pod.ex:240`) et porte le profil EFFECTIF — canon plus overlays plus opts du spawn — pas le
# yaml du catalogue. C'est exactement la bonne source : ce que ce pod-ci a recu, pas ce qu'un role
# recoit en general.
#
# Ce que cette sonde ne fait PAS : reparer. Une non-conformite est un CONSTAT. La corriger ici
# reviendrait a effacer la mesure pour faire verdir l'instrument — et un outil qui se met en
# conformite avec lui-meme ne mesure plus rien.

# ⚠ AUCUN `set -e` ICI, ET C'EST LA DOCTRINE DES SONDES. Une sonde qui meurt n'emet AUCUN verdict :
# son plan disparait du rapport sans que rien ne le signale. Elle doit survivre a ses propres
# echecs pour les DIRE (`unknown`, `degraded`) — c'est precisement ce que la sonde 10 existe pour
# empecher. Pas de `-u` non plus : une variable absente est un fait a rapporter, pas une mort.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="self"
POD_HOME="${LCARS_POD_HOME:-$HOME}"
CAP="$POD_HOME/.cap-profile.json"

# Trois contextes, pas deux, et les confondre fausse la moitie des liaisons :
#   dedans   — je SUIS le pod : mounts, capabilities et env sont les miens
#   dehors   — j'INSPECTE un pod par son repertoire : les fichiers sont lisibles, le noyau non
#   absent   — aucun pod : rien a confronter
sotf_self_context() {
  if [[ -n "${LCARS_POD_ID:-}" ]]; then echo "dedans"
  elif [[ -r "$CAP" ]]; then echo "dehors"
  else echo "absent"; fi
}
CTX="$(sotf_self_context)"

# ── Observateurs ─────────────────────────────────────────────────────────────────────────────────
# Chacun recoit la valeur DECLAREE en $1 et rend `verdict|evidence`. Ils sont du CODE et doivent le
# rester : ce sont des mecanismes de lecture, pas des attentes. L'attente vient du cap-profile.

# ⚠ `obs_launcher_tools` A ETE RETIRE — et son absence est une DECISION, pas un oubli.
#
# Il confrontait `.spec.scope.allowedTools` a la liste que `claude_launch.dbg` disait avoir passee au
# binaire vendor : la divergence A-8 rendue mecanique. Sa source a disparu — le launcher n'ecrit plus
# aucune trace dans le pod, parce qu'il tourne DANS le bwrap et que tout ce qu'il ecrit, l'agent
# confine le lit. Une trace de boot lui tendait la recette de son propre conteneur.
#
# Le pod est donc AVEUGLE sur ce point, exprès : il ne verifie plus l'accord entre sa liste declaree
# et celle qui a ete posee. Une empreinte (sha de la liste triee) aurait rendu la detection sans
# reveler le contenu ; ecartee — arbitrage user 2026-08-15 : on ne laisse pas au pod la recette de son
# conteneur, et une remediation exige de toute facon de toucher la source et de rebuilder, ce n'est pas
# un flag a remettre.
#
# Ne pas le "reparer" en re-introduisant une trace cote pod. La divergence declaration/launcher se
# mesure depuis l'HOTE, ou pas du tout.

# `knowledge.skills` declare, `~/.claude/skills/` observe. C'est la classe A-11.
obs_skills_installed() {
  local declared="$1" dir="$POD_HOME/.claude/skills"
  [[ -n "$declared" && "$declared" != "null" ]] || { echo "inactive|aucun skill declare"; return; }
  local missing="" s
  for s in ${declared//,/ }; do [[ -e "$dir/$s" ]] || missing="$missing $s"; done
  if [[ ! -d "$dir" ]]; then
    echo "degraded|declares :${declared//,/ } · le repertoire $dir n'existe pas — AUCUN n'est provisionne"
  elif [[ -n "$missing" ]]; then
    echo "degraded|declares mais absents du disque :$missing"
  else
    echo "operational|les $(echo ${declared//,/ } | wc -w) skills declares sont presents"
  fi
}

# `interlocutor` declare vs le contrat reellement injecte dans `.lcars/protocole-user.md`.
obs_protocol_injected() {
  local declared="$1" f="$POD_HOME/.lcars/protocole-user.md"
  [[ -r "$f" ]] || { echo "unreachable|protocole-user.md absent ($f)"; return; }
  local m h; m=0; h=0
  grep -q 'engage' "$f" && m=1
  grep -qi 'humain a ce terminal\|humain à ce terminal' "$f" && h=1
  local seen
  case "$m$h" in 10) seen="fleet" ;; 11) seen="both" ;; 01) seen="human" ;; *) seen="?" ;; esac
  if [[ "$seen" == "$declared" ]]; then
    echo "operational|contrat injecte conforme a la declaration ($declared, $(wc -c <"$f") o)"
  elif [[ "$seen" == "?" ]]; then
    echo "unknown|contrat injecte non identifiable (ni marqueur machine ni marqueur humain)"
  else
    echo "degraded|DIVERGENCE — declare '$declared', injecte '$seen'"
  fi
}

# `invocation.effort` declare vs `CLAUDE_EFFORT` reellement pose dans l'env.
obs_effort_env() {
  local declared="$1"
  [[ "$CTX" == dedans ]] || { echo "unreachable|env du pod non lisible depuis l'exterieur"; return; }
  local seen="${CLAUDE_EFFORT:-}"
  [[ -n "$seen" ]] || { echo "degraded|declare '$declared', CLAUDE_EFFORT absent de l'env"; return; }
  [[ "$seen" == "$declared" ]] \
    && echo "operational|effort '$seen' conforme" \
    || echo "degraded|DIVERGENCE — declare '$declared', env porte '$seen'"
}

# `metadata.containment: bwrap` declare vs le confinement reellement subi.
obs_containment() {
  local declared="$1"
  [[ "$CTX" == dedans ]] || { echo "unreachable|confinement non observable depuis l'exterieur du pod"; return; }
  local caps host; caps="$(grep -m1 '^CapEff:' /proc/self/status 2>/dev/null | awk '{print $2}')"
  host="$(hostname 2>/dev/null)"
  if [[ "$declared" == "bwrap" ]]; then
    if [[ "$caps" == "0000000000000000" && "$host" == lcars-pod-* ]]; then
      echo "operational|CapEff=0, hostname '$host' — confinement conforme"
    else
      echo "degraded|declare bwrap mais CapEff='$caps' hostname='$host'"
    fi
  else
    echo "unknown|containment '$declared' hors du seul cas verifiable ici (bwrap)"
  fi
}

# `metadata.mounts` declares vs ce que le noyau montre reellement.
obs_mounts() {
  local declared="$1"
  [[ "$CTX" == dedans ]] || { echo "unreachable|table de montage du pod non observable depuis l'exterieur"; return; }
  [[ -n "$declared" && "$declared" != "null" ]] || { echo "inactive|aucun mount declare"; return; }
  local missing="" p
  for p in ${declared//,/ }; do
    grep -qE " ${p}( |/)" /proc/self/mountinfo 2>/dev/null || missing="$missing $p"
  done
  [[ -z "$missing" ]] \
    && echo "operational|les $(echo ${declared//,/ } | wc -w) mounts declares sont presents dans mountinfo" \
    || echo "degraded|declares mais ABSENTS de mountinfo :$missing"
}

# ── Le catalogue de liaisons ─────────────────────────────────────────────────────────────────────
# id ¤ chemin jq de la DECLARATION ¤ observateur ¤ ce que l'ecart ne prouve pas
#
# Ajouter une verification = ajouter UNE ligne et un observateur. Aucune attente n'est ecrite ici :
# la colonne 2 dit ou la lire.
BINDINGS=(
"self.skills¤.spec.knowledge.skills¤obs_skills_installed¤Presence sur disque seulement. Un skill present n'est pas un skill monte dans la session, ni un skill valide."
"self.protocol¤.spec.interlocutor¤obs_protocol_injected¤Identifie le contrat par ses marqueurs. Ne dit pas si l'agent le SUIT, ni si un autre contrat contradictoire est injecte ailleurs (issues/, system-prompt)."
"self.effort¤.spec.invocation.effort¤obs_effort_env¤L'env porte ce que le launcher a pose. Ne prouve pas que le binaire vendor l'honore."
"self.containment¤.metadata.containment¤obs_containment¤Deux indices (capabilities, hostname), pas une preuve d'isolation complete : ni les mounts, ni le netns, ni seccomp ne sont juges ici."
"self.mounts¤.metadata.mounts[].path¤obs_mounts¤Presence dans mountinfo seulement. Ne dit rien du MODE reel (ro/rw) ni de ce que le chemin contient."
)

# ── La boucle ────────────────────────────────────────────────────────────────────────────────────
run_bindings() {
  local rec id path fn cannot declared out verdict evidence
  for rec in "${BINDINGS[@]}"; do
    IFS='¤' read -r id path fn cannot <<< "$rec"
    # `flatten` est load-bearing : `.spec.knowledge.skills` EST un tableau, donc `[...]` donne un
    # tableau de tableau et `tostring` rendait le JSON brut (`["a" "b"]`) au lieu des elements.
    declared="$(jq -r "[$path] | flatten | map(select(. != null) | tostring) | join(\",\")" "$CAP" 2>/dev/null)"
    if [[ -z "$declared" ]]; then
      emit "$id" "$PLANE" "inactive" "local" "jq '$path' .cap-profile.json" \
        "rien de declare a ce chemin" \
        "Absence de DECLARATION : il n'y a rien a confronter. Ne prejuge pas de l'observable."
      continue
    fi
    out="$($fn "$declared")"
    verdict="${out%%|*}"; evidence="${out#*|}"
    emit "$id" "$PLANE" "$verdict" "$([[ "$CTX" == dedans ]] && echo local || echo "local (pod inspecte de l'exterieur)")" \
      "declare: $path → « $(trim "$declared" 90) »" \
      "$evidence" "$cannot"
  done
}

# ── La couverture — ce qu'AUCUNE liaison ne regarde ───────────────────────────────────────────────
# La question qu'un jeu de checks ecrits a la main ne peut pas poser. Elle enumere les champs
# scalaires du cap-profile et retire ceux qu'une liaison couvre : le reste est declare et non
# confronte. C'est un aveu de perimetre, pas une faute.
probe_coverage() {
  local bound total unbound
  # `awk -F` et pas `cut -d` : le separateur est multi-octets (¤), et `cut` exige UN caractere.
  # Il echouait en silence cote stderr, la couverture annoncait 1 champ lie sur 27 — un chiffre faux
  # qui rendait le perimetre plus etroit qu'il n'est. Une sonde de couverture qui sous-estime est
  # pire qu'absente : elle donne une excuse a ne pas regarder.
  bound="$(printf '%s\n' "${BINDINGS[@]}" | awk -F'¤' '{print $2}' | sed 's/^\.//; s/\[\]//g' | sort -u)"
  total="$(jq -r '[paths(scalars)] | map(join(".")) | .[]' "$CAP" 2>/dev/null | sed 's/\.[0-9]\+//g' | sort -u)"
  unbound="$(comm -23 <(printf '%s\n' "$total") <(printf '%s\n' "$bound") | tr '\n' ' ')"
  local n; n="$(printf '%s\n' "$total" | wc -l)"
  emit "self.coverage" "$PLANE" "unknown" "local" \
    "jq 'paths(scalars)' .cap-profile.json vs les liaisons declarees" \
    "$(printf '%s\n' "$bound" | wc -l)/$n champs confrontes · NON couverts : $(trim "$unbound" 400)" \
    "Un champ non couvert n'est PAS conforme : il n'est pas regarde. Cette ligne mesure mon perimetre, pas la sante du pod."
}

# ── Runner ───────────────────────────────────────────────────────────────────────────────────────
sotf_init
case "$CTX" in
  absent)
    emit "self.cap_profile" "$PLANE" "inactive" "local" "test -r $CAP" \
      "aucun cap-profile ($CAP) — ni pod, ni repertoire de pod inspecte" \
      "Absence de catalogue : il n'y a rien a confronter. Ne dit rien d'un pod reel."
    ;;
  *)
    emit "self.cap_profile" "$PLANE" "operational" "local" "test -r $CAP" \
      "profil EFFECTIF lu ($CTX) : role=$(jq -r '.metadata.name // "?"' "$CAP" 2>/dev/null) · $(wc -c <"$CAP" 2>/dev/null) o" \
      "C'est le profil ECRIT AU SPAWN — canon + overlays + opts. Il ne dit pas ce que le catalogue declare pour ce role en general."
    run_bindings
    probe_coverage
    ;;
esac
exit "$(sotf_exit_code)"
