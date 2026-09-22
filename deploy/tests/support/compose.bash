# SOURCE: deploy/tests/support/compose.bash
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: helper bats — un cas qui rend un compose par docker compose se saute, en le nommant, sur un poste sans lui
#
#   load ../support/compose
#   compose_requis    en tête du cas (ou de setup) : un skip nommé quand « docker compose » ne répond pas
#
# Le rendu (« docker compose config ») ne demande aucun daemon, seulement la CLI et son plugin compose.
# La porte compte les cas sautés dans son verdict : un poste sans compose le voit.

compose_requis() {
  docker compose version >/dev/null 2>&1 \
    || skip "docker compose absent de ce poste : le compose ne se rend pas ici"
}
