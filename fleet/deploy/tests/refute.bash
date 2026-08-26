# SOURCE: fleet/deploy/tests/refute.bash
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: helper bats — une assertion NEGATIVE qui echoue vraiment
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
#
# ⚠ `! cmd` N'EST PAS UNE ASSERTION SOUS BATS. Bash exempte d'`errexit` toute commande niee par `!`
# (POSIX : « the -e setting shall be ignored when the command is preceded by ! »). Une ligne
# `! grep -q MOTIF fichier` qui ECHOUE — donc qui vient de trouver ce qu'elle interdit — ne tue donc
# pas le test : elle s'execute, rend 1, et bats passe a la ligne suivante. Le test ne rougit que si
# cette ligne est la DERNIERE de son bloc, parce qu'alors son code devient celui du test.
#
# Consequence : toute assertion niee suivie d'une autre instruction est INERTE. Elle se lit comme
# une garde, elle n'en est pas une, et elle est verte au moment precis ou ce qu'elle interdit arrive.
#
# ⚠ MESURE DU 2026-08-26, PAR MUTATION, SUR CE DEPOT. Cinq temoins muets prouves :
#   · « AUCUNE unite ne pose User= »            → `User=nobody` reinjecte dans lcars-landing : VERT
#   · « l'environnement ne REDIT pas les defauts » → un `${VAR:-defaut}` mort reinjecte : VERT
#   · « le nom REEL du fichier tmpfiles »       → l'ancien nom remis au manifeste : VERT
#   · « B3 : le bloc gere converge vers la SOURCE » → la purge de l'ancien bloc cassee : VERT
#   · « TERM se propage a l'enfant »            → le `kill` retire de la trap : VERT, orphelin vivant
#
# Le corpus en portait 54 occurrences de cette forme au moment de la mesure. Ce fichier est la
# reponse mecanique : un APPEL DE FONCTION, lui, est soumis a `errexit` — sa valeur de retour non
# nulle tue le test ou qu'il soit dans le bloc.
#
# Usage :
#   load refute
#   refute grep -q 'motif' "$fichier"
#   refute kill -0 "$pid"
#
# ⚠ ET LE MESSAGE NOMME CE QU'ON A TROUVE. Une garde qui echoue en silence oblige a relire le test
# pour savoir ce qu'elle interdisait ; celle-ci le dit dans sa propre sortie.
refute() { # refute <cmd...> — echoue si <cmd> REUSSIT
  if "$@"; then
    echo "REFUTE : « $* » a REUSSI, alors que ce temoin exige qu'elle echoue" >&2
    return 1
  fi
  return 0
}

# ⚠ ET LE PENDANT POUR LES TUBES, PARCE QUE `refute` NE PEUT PAS LES PRENDRE. `refute code | grep -q X`
# se lit « refute code », tube vers grep — la negation porterait sur le mauvais bout. Les deux tiers
# des sites du corpus sont de cette forme (`! code | grep -q …`, `! sed … | grep -q …`).
#
# Ici la fonction est le DERNIER maillon du tube. Le statut d'un tube est celui de son dernier
# maillon, et un tube qui echoue SANS `!` devant est bien soumis a `errexit` : l'assertion mord.
#
# Elle IMPRIME ce qu'elle a trouve, borne a cinq lignes. Une garde qui dit seulement « quelque chose
# ne va pas » oblige a rejouer la commande a la main pour savoir quoi.
refute_out() { # <cmd> | refute_out <motif ERE> — echoue si le motif est TROUVE sur stdin
  local motif="${1:?refute_out attend un motif}" trouve
  trouve="$(grep -E -- "$motif" || true)"
  [[ -z "$trouve" ]] && return 0
  {
    echo "REFUTE : « $motif » TROUVE, alors que ce temoin l'interdit :"
    printf '%s\n' "$trouve" | head -5
  } >&2
  return 1
}
