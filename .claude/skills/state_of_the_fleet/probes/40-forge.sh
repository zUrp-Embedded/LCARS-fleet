#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/40-forge.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 40 : la forge
#
# THE PLANE WHERE AMBIGUITY IS THE NORM, which is why `unknown` exists at all. Measured on a live
# pod: `GET /api/v1/orgs/fleet` answers 404 while `GET /api/v1/orgs/fleet/repos` answers `200 []`.
# Contradictory only if one forgets that ANONYMOUS 404 conflates "absent" with "not visible to you".
# The agent that hit this had the discipline to say so. A probe must not depend on discipline: every
# anonymous verdict here carries its own two readings.
#
# NO CREDENTIALS IN A POD — measured: no `.netrc`, no `.git-credentials`, `GIT_CONFIG_GLOBAL=/dev/null`.
# So this probe reads what an anonymous caller can read, and says `unreachable` for the rest rather
# than pretending an unauthenticated answer is the whole picture.
#
# We never WRITE. Not even a harmless-looking create: `project_create` makes a real repo, a dual-dir
# and a scaffold. A diagnostic that mutates to measure is not a diagnostic.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="forge"
FORGE="${FORGE_BASE_URL:-}"
FORGE="${FORGE%/}"

# ── L'adresse est-elle seulement connue ───────────────────────────────────────────────────────────
# Unlike the fleet's ports, the forge URL cannot be derived from anything: it is a deployment fact.
# Absent, every probe below is blind and says so ONCE, here, instead of five confusing times.
probe_configured() {
  if [[ -z "$FORGE" ]]; then
    # `inactive`, NOT `unreachable`, et la distinction a ete apprise sur deux specimens : mon
    # instrument n'est pas casse, il n'y a simplement RIEN de declare a atteindre. Marquer ce cas
    # aveugle faisait basculer tout le rapport en AVEUGLE sur une boite parfaitement saine dont
    # personne n'a configure de forge — une fausse alarme deguisee en constat.
    emit "forge.configured" "$PLANE" "inactive" "local" 'test -n "$FORGE_BASE_URL"' \
      "aucune forge declaree (FORGE_BASE_URL vide ou absente)" \
      "Absence de DECLARATION, pas de mesure ratee : je ne dis rien d'une forge qui existerait ailleurs sans etre annoncee a ce processus."
    return 1
  fi
  emit "forge.configured" "$PLANE" "operational" "local" 'echo $FORGE_BASE_URL' \
    "adresse declaree : $FORGE" \
    "Une adresse declaree n'est pas une forge qui repond. La joignabilite est mesuree juste apres."
}

# ── Joignable ─────────────────────────────────────────────────────────────────────────────────────
# `/api/v1/version` is the cheapest authenticated-free endpoint and it answers with the software's
# own version — enough to prove the thing on the other end is a forge, not merely a socket.
probe_reachable() {
  if ! http_probe "$FORGE/api/v1/version" 6; then
    emit "forge.reachable" "$PLANE" "unreachable" "reseau" "curl $FORGE/api/v1/version" \
      "curl absent" "Aveugle : ni joignable ni injoignable prouve."
    return 1
  fi
  case "$SOTF_HTTP_CODE" in
    2*) emit "forge.reachable" "$PLANE" "operational" "reseau" "curl $FORGE/api/v1/version" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 120)" \
          "La forge repond. Ne dit rien de son CONTENU : comptes, org et repos sont des questions distinctes." ;;
    000) emit "forge.reachable" "$PLANE" "degraded" "reseau" "curl $FORGE/api/v1/version" \
          "aucune reponse : $(trim "$SOTF_HTTP_BODY" 200)" \
          "Ne separe pas forge arretee, DNS mort et reseau coupe : les trois donnent ce meme silence."
         return 1 ;;
    *)  emit "forge.reachable" "$PLANE" "degraded" "reseau" "curl $FORGE/api/v1/version" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
          "Un service repond a cette adresse sans se comporter en forge : proxy, mauvaise cible, ou forge en vrac."
        return 1 ;;
  esac
}

# ── L'identite du provisioning, en anonyme ────────────────────────────────────────────────────────
# THE probe that must not conclude. A 404 without credentials means "absent OR invisible", full stop.
# Reporting it as absence is how a diagnostic sends an operator provisioning an account that already
# exists.
probe_identity() {
  local human="${LCARS_HUMAN:-${USER:-}}" org="${FORGE_ORG:-}"

  # L'org n'est declaree NULLE PART d'atteignable depuis un pod : elle vit dans `forge.tf`, cote
  # provisioning. Pas de defaut ici, meme vraisemblable : une sonde qui interroge un nom devine
  # rend un 404 qui ne prouve rien — ni que l'org manque, ni qu'elle est la sous un autre nom.
  # Sans nom declare, on le dit.
  if [[ -z "$org" ]]; then
    emit "forge.org" "$PLANE" "inactive" "reseau" 'test -n "$FORGE_ORG"' \
      "aucun nom d'org declare a ce processus (FORGE_ORG absente, et rien ne la porte cote runtime)" \
      "Je ne sais pas QUELLE org chercher. Un test sur un nom devine ne prouverait rien — pas meme son absence."
  else
    probe_org "$org"
  fi

  probe_human_account "$human"
}

# L'org et le compte humain sont deux questions INDEPENDANTES. Le premier correctif les avait
# couplees par un `return` : ne pas connaitre le nom de l'org faisait sauter la verification du
# compte, qui n'en depend pas. Un correctif qui emporte une mesure voisine est un demi-correctif.
probe_org() {
  local org="$1" u="$FORGE/api/v1/orgs/$org"
  if http_probe "$u" 6; then
    case "$SOTF_HTTP_CODE" in
      2*)  emit "forge.org" "$PLANE" "operational" "reseau" "curl $u" \
             "org '$org' (nom fourni par FORGE_ORG) visible en anonyme (HTTP $SOTF_HTTP_CODE)" \
             "Visible ne veut pas dire correctement peuplee : teams et memberships ne sont pas lisibles ici." ;;
      404) emit "forge.org" "$PLANE" "unknown" "reseau" "curl $u" \
             "HTTP 404 · $(trim "$SOTF_HTTP_BODY" 120)" \
             "En anonyme, 404 ne distingue PAS 'org absente' de 'org privee, invisible sans auth'. Seul un token tranche — ne pas provisionner sur cette base." ;;
      *)   emit "forge.org" "$PLANE" "unknown" "reseau" "curl $u" \
             "HTTP $SOTF_HTTP_CODE" "Code inattendu : etat de l'org indetermine." ;;
    esac
  else
    emit "forge.org" "$PLANE" "unreachable" "reseau" "curl $u" "curl absent" "Aveugle sur l'org."
  fi

}

probe_human_account() {
  local human="$1" u
  if [[ -z "$human" ]]; then
    emit "forge.human_account" "$PLANE" "unreachable" "reseau" 'curl $FORGE/api/v1/users/$LCARS_HUMAN' \
      "nom du compte humain inconnu (ni LCARS_HUMAN ni USER)" \
      "Je ne sais pas QUEL compte chercher : l'absence de reponse ne dit rien du provisioning."
    return
  fi
  u="$FORGE/api/v1/users/$human"
  if http_probe "$u" 6; then
    case "$SOTF_HTTP_CODE" in
      2*)  emit "forge.human_account" "$PLANE" "operational" "reseau" "curl $u" \
             "compte '$human' visible" \
             "Le compte existe. Son appartenance a l'equipe 'humans' n'est PAS lisible en anonyme : l'onboarding peut encore echouer dessus." ;;
      404) emit "forge.human_account" "$PLANE" "unknown" "reseau" "curl $u" \
             "HTTP 404 pour '$human' · $(trim "$SOTF_HTTP_BODY" 120)" \
             "Anonyme : absent OU non-visible. C'est la cause la plus frequente d'un onboarding refuse, mais elle se CONFIRME avec un token admin avant tout geste." ;;
      *)   emit "forge.human_account" "$PLANE" "unknown" "reseau" "curl $u" \
             "HTTP $SOTF_HTTP_CODE" "Etat du compte indetermine." ;;
    esac
  else
    emit "forge.human_account" "$PLANE" "unreachable" "reseau" "curl $u" "curl absent" "Aveugle sur le compte humain."
  fi
}

# ── Les credentials dont JE dispose ───────────────────────────────────────────────────────────────
#
# ⚠ CETTE SONDE MESURAIT UN MECANISME RETIRE. Elle testait `-r "$FORGE_TOKEN_FILE"` et comptait les
# `*.gitea_token` d'un repertoire : deux lectures qui ne repondent plus a la question posee. Le BEAM
# ne lit plus ces fichiers, il DEMANDE a `roles.sock` ; et apres la fermeture des modes, un uid
# humain ne pourra meme plus traverser le repertoire. La sonde aurait donc rendu « aucun credential
# accessible » sur une boite parfaitement capable de pousser — un rouge faux, dans un rapport dont
# tout l'objet est de dire l'etat exact.
#
# CE QUI SE MESURE MAINTENANT EST LA PORTE, ET C'EST LA MEME CLASSE DE MESURE QU'AVANT : une
# presence, jamais une valeur, jamais un appel qui depenserait le credential. Ouvrir la socket ET
# DEMANDER rendrait un jeton — donc materialiserait un secret dans le process d'une sonde dont la
# sortie finit dans un log de conversation. On regarde que la porte existe, pas ce qu'il y a
# derriere.
probe_credentials() {
  local sock="${LCARS_ROLES_SOCKET:-/run/lcars/authority/roles.sock}"

  if [[ -S "$sock" ]]; then
    emit "forge.credentials" "$PLANE" "operational" "local" 'test -S "$LCARS_ROLES_SOCKET"' \
      "service d'autorite en ecoute ($sock)" \
      "PRESENCE DE LA PORTE seulement. Ni que la forge repond, ni que ce demandeur-ci obtiendrait un jeton : le savoir demanderait d'en depenser un."
  else
    # LA PORTE FERMEE ET LA PORTE GARDEE NE SE DISENT PAS PAREIL. Dans un pod, l'absence est
    # ATTENDUE et par conception. Sur un hote, c'est une unite qui ne tourne pas.
    emit "forge.credentials" "$PLANE" "inactive" "local" 'test -S "$LCARS_ROLES_SOCKET"' \
      "aucun service d'autorite joignable depuis ici ($sock absent)" \
      "ATTENDU dans un pod (aucun credential n'y est joignable, par design). Sur un hote, c'est « systemctl status lcars-catalogue » : tout ce qui precede est ANONYME, donc partiellement aveugle."
  fi
}

# ── Runner ────────────────────────────────────────────────────────────────────────────────────────
sotf_init
if probe_configured && probe_reachable; then
  probe_identity
else
  # Meme trichotomie en aval : rien de declare → `inactive` (sans objet) ; declare mais muet →
  # `unreachable` (je n'ai pas pu mesurer). Les confondre noie le cas interessant dans le banal.
  if [[ -z "$FORGE" ]]; then
    fv="inactive"; fr="aucune forge declaree — sonde sans objet"
  else
    fv="unreachable"; fr="forge declaree mais injoignable — sonde non lancee"
  fi
  emit "forge.org" "$PLANE" "$fv" "reseau" "(non lancee)" "$fr" \
    "Non mesure. N'affirme ni presence ni absence de l'org."
  emit "forge.human_account" "$PLANE" "$fv" "reseau" "(non lancee)" "$fr" \
    "Non mesure. N'affirme ni presence ni absence du compte."
fi
probe_credentials
exit "$(sotf_exit_code)"
