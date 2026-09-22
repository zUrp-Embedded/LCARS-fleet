# SOURCE: deploy/tests/refute.bash
# AUTHOR: bob
# STARDATE: 2026-08-26
# STATUS: helper bats — une assertion NEGATIVE qui echoue vraiment
#
# `! cmd` N'EST PAS UNE ASSERTION SOUS BATS : POSIX exempte d'`errexit` toute commande niee par `!`.
# Elle s'execute, rend 1, et bats passe a la suite — elle ne mord QUE si elle est la DERNIERE ligne
# de son bloc `@test`. Partout ailleurs elle est verte au moment precis ou ce qu'elle interdit
# arrive. Un appel de fonction, lui, est soumis a `errexit` : il tue le test ou qu'il soit.
#
#   load refute
#   refute grep -q 'motif' "$f"      # echoue si la commande REUSSIT
#   cmd | refute_out [-i] 'motif ERE'   # echoue si le motif est TROUVE sur stdin
#
# ⚠ Pour un tube, c'est `refute_out`, et il doit en etre le DERNIER maillon : `refute cmd | grep -q X`
# se lit « refute cmd », tube vers grep — la negation porterait sur le mauvais bout. Les deux
# fonctions nomment sur stderr ce qu'elles ont trouve.

refute() {
  if "$@"; then
    echo "REFUTE : « $* » a REUSSI, alors que ce temoin exige qu'elle echoue" >&2
    return 1
  fi
  return 0
}

refute_out() {
  # `errexit` exempte une liste `&&` dont le test est faux, sauf quand elle est la DERNIERE commande
  # de la fonction : son 1 devient alors le code rendu, et l'appelant meurt. `[[ -z … ]] && return 0`
  # est donc sur ici, parce qu'il n'est pas en fin de fonction ; un trouve continue jusqu'au message
  # et au `return 1`. Le drapeau est colle au `-E` (`grep -E` ou `grep -Ei`) pour n'avoir aucun
  # tableau a developper sous `set -u`.
  local ci=""
  if [[ "${1:-}" == "-i" ]]; then ci="i"; shift; fi
  local motif="${1:?refute_out attend un motif}" trouve
  trouve="$(grep -E"$ci" -- "$motif" || true)"
  [[ -z "$trouve" ]] && return 0
  {
    echo "REFUTE : « $motif » TROUVE, alors que ce temoin l'interdit :"
    printf '%s\n' "$trouve" | head -5
  } >&2
  return 1
}
