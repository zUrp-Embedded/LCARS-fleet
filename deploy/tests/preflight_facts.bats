#!/usr/bin/env bats
# SOURCE: deploy/tests/preflight_facts.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests for 00-preflight — le preflight des DEUX rails, et son canal de faits
#
# ─── CE QUE CES TEMOINS FERMENT ─────────────────────────────────────────────────────────────────
#
# `00-preflight` etait le preflight du rail POSTE : il ne mesurait docker que sous WSL, et le reste
# vivait en double dans `install.sh`. Le canon de la porte proscrit cette duplication (« le preflight
# duplique : une seule mesure »), donc le module mesure pour les DEUX rails et rend ses resultats
# deux fois — en lignes pour un humain, en faits `nom=valeur` pour un appelant qui doit DECIDER.
#
# ⚠ LA PROPRIETE CENTRALE EST QUE MESURER N'EST PAS REFUSER. Le module sait desormais plus de choses
# qu'avant ; il ne doit refuser ni plus, ni ailleurs, ni pour d'autres raisons. Un preflight qui
# durcit ses verdicts en gagnant des sondes casserait toutes les machines qui passaient hier.
#
# ⚠ SC2016 : ces temoins LISENT du code. Leurs motifs portent des `${VAR:-defaut}` qui doivent
# atteindre l'outil TELS QUELS.
# shellcheck disable=SC2016

load refute

setup() {
  # ⚠ LE DECOR POSSEDE L'ENVIRONNEMENT. Ce module lit `LCARS_ALLOW_ANY_HOST`, `FORGE_BASE_URL`,
  # `LCARS_DOCKER_SOCKETS`, `PROV_DOCKER_BIN`, `PROV_SUBSTRATE` — toute la famille, donc on efface
  # la FAMILLE et pas les noms qu'on connait : le prochain drapeau ne doit pas rouvrir le trou.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)
  unset SUDO_USER

  MOD="$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  [ -f "$MOD" ]
  [ -f "$LIB" ]
  FACTS="$BATS_TEST_TMPDIR/facts"

  # La CLI docker du decor : une doublure qui ECHOUE, declaree par `PROV_DOCKER_BIN`.
  # ⚠ ELLE SE DECLARE, ELLE NE SE GLISSE PAS DANS LE PATH — sous wsl la sonde essaie DELIBEREMENT la
  # CLI du montage Docker Desktop AVANT le PATH, donc une doublure posee dans le PATH n'est jamais
  # prise sur une machine qui a Docker Desktop. Mesure du 2026-08-31, banc 2004 : c'est exactement
  # ce defaut qui rendait `provision_runner.bats:542` vert ici et rouge la-bas.
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/docker"; chmod 0755 "$BIN/docker"
}

# preflight <substrat> [VAR=val…] — joue le module et remplit "$FACTS"
preflight() {
  local sub="$1"; shift
  run env PROV_FACTS_FILE="$FACTS" PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight \
      PROV_SUBSTRATE="$sub" PROV_DOCKER_BIN="$BIN/docker" \
      LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/absent.sock" \
      PATH="$BIN:/usr/bin:/bin" \
      "$@" bash "$MOD" check
}

fact() { # fact <nom> -> sa valeur, vide si absent
  sed -n "s/^$1=//p" "$FACTS" 2>/dev/null | tail -1
}

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS present" {
  run head -8 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
}

# ─── LE CANAL ───────────────────────────────────────────────────────────────────────────────────

@test "sans PROV_FACTS_FILE le module ne change RIEN — le canal est optionnel" {
  # Un module qui exigerait le canal pour tourner ferait de la porte une dependance du
  # provisionnement, alors que c'est l'inverse.
  run env PROVISION_LIB="$LIB" PROVISION_MODULE=00-preflight PROV_SUBSTRATE=docker \
      PROV_DOCKER_BIN="$BIN/docker" LCARS_DOCKER_SOCKETS="$BATS_TEST_TMPDIR/absent.sock" \
      PATH="$BIN:/usr/bin:/bin" bash "$MOD" check
  [ ! -e "$FACTS" ]
  [[ "$output" == *"00-preflight"* ]]
}

@test "les faits que la PORTE consomme sont TOUS poses — la liste est le contrat" {
  # ⚠ CETTE LISTE EST LE CONTRAT ENTRE DEUX FICHIERS, et c'est pour ca qu'elle est ici et pas dans un
  # commentaire. La porte restreint son menu sur ces noms ; en retirer un sans toucher la porte la
  # laisse lire du vide et decider quand meme — un menu faux, sans une ligne d'erreur.
  preflight docker
  local f
  for f in os bash arch ram_mb disque_mb substrat consent wsl2 wslconf userns_knob \
           docker docker_why compose forge_fournie forge_joignable sudo curl git; do
    grep -qE "^$f=" "$FACTS" || { echo "fait ABSENT : $f" >&2; return 1; }
  done
}

@test "un fait par ligne, jamais deux valeurs pour un nom" {
  preflight docker
  local n; n="$(cut -d= -f1 "$FACTS" | sort | uniq -d | head -1)"
  [ -z "$n" ] || { echo "fait pose DEUX fois : $n" >&2; return 1; }
}

# ─── DOCKER : MESURE PARTOUT, REFUS LA OU IL ETAIT DEJA ─────────────────────────────────────────

@test "docker est mesure sur TOUT substrat — c'etait le trou du preflight" {
  # Le rail CONTENEUR tourne sur n'importe quel substrat et docker y est sa seule condition d'existence.
  # Ne le mesurer que sous WSL laissait la porte deviner — ou refaire la sonde, ce qu'elle faisait.
  local s
  for s in wsl linux docker; do
    rm -f "$FACTS"
    preflight "$s" LCARS_ALLOW_ANY_HOST=1
    [ -n "$(fact docker)" ] || { echo "substrat $s : aucun fait docker" >&2; return 1; }
    [ -n "$(fact docker_why)" ] || { echo "substrat $s : docker absent sans raison" >&2; return 1; }
  done
}

@test "le VERDICT de docker ne bouge pas : refus sous WSL, fait ailleurs" {
  # ⚠ C'EST LA GARDE DE L'EXTENSION ELLE-MEME. Le module sait maintenant distinguer « absent » de
  # « refuse a cet utilisateur » ; il ne doit pas s'en servir pour refuser autrement. Sous WSL la
  # forge n'a AUCUNE autre forme que docker, donc c'est un echec de sonde (rc 2) — comme avant.
  preflight wsl
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"* ]]
  # Hors WSL, le meme fait ne refuse rien : le rail poste POSE docker sur un linux declare.
  rm -f "$FACTS"
  preflight linux LCARS_ALLOW_ANY_HOST=1
  [ "$status" -ne 2 ]
}

@test "absent et refuse sont DEUX faits, parce que ce sont deux gestes" {
  # Un daemon absent se pose ; un daemon qui refuse cet utilisateur se regle par un groupe. La porte
  # doit pouvoir nommer le geste, donc le fait les separe la ou le verdict les confond.
  preflight docker
  [ "$(fact docker)" = "absent" ]
  run grep -nE 'p_fact docker (refuse|absent)' "$MOD"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"refuse"* ]]
  [[ "${lines[0]}" == *"absent"* ]]
}

# ─── LES FAITS NEUFS ────────────────────────────────────────────────────────────────────────────

@test "forge FOURNIE : l'URL est un fait, et sa joignabilite en est un autre" {
  # `FORGE_BASE_URL` posee = « j'ai deja une forge, consomme-la ». Le rail conteneur s'y raccroche : si
  # elle ne repond pas, il echouera au premier geste — et la porte doit le dire AVANT la validation,
  # pas apres.
  preflight docker FORGE_BASE_URL="http://127.0.0.1:1/forge-qui-n-existe-pas"
  [ "$(fact forge_fournie)" = "http://127.0.0.1:1/forge-qui-n-existe-pas" ]
  [ "$(fact forge_joignable)" = "non" ]
}

@test "forge ABSENTE : le fait est vide, la joignabilite sans objet — jamais « non »" {
  # « non » dirait « mesure faite, elle ne repond pas ». Il n'y a rien a joindre : c'est autre chose,
  # et la porte n'affiche pas la meme ligne.
  preflight docker
  [ -z "$(fact forge_fournie)" ]
  [ "$(fact forge_joignable)" = "sans-objet" ]
}

@test "wsl.conf ETRANGER est un avertissement, jamais un refus" {
  # Le rail poste le REMPLACE en entier — c'est la frontiere de securite du conteneur. L'operateur
  # doit le voir avant de valider ; refuser pour autant bloquerait une machine parfaitement saine.
  run grep -n 'p_fact wslconf etranger' "$MOD"
  [ "$status" -eq 0 ]
  local bloc; bloc="$(sed -n '/p_fact wslconf etranger/,/^  fi$/p' "$MOD")"
  grep -q 'p_warn' <<<"$bloc"
  refute grep -qE 'p_fail|p_drift' <<<"$bloc"
}

@test "sudo : trois etats, et root en est un — le module tourne sous root a l'apply" {
  # Rendre « absent » quand on EST root serait faux : la question ne se pose pas.
  preflight docker
  case "$(fact sudo)" in
    root|oui|absent) : ;;
    *) echo "etat sudo inattendu : $(fact sudo)" >&2; return 1 ;;
  esac
  run grep -c 'p_fact sudo ' "$MOD"
  [ "$output" -eq 3 ]
}

# ─── LE MUR ─────────────────────────────────────────────────────────────────────────────────────

@test "MUR : aucun fait n'est pose dans un bloc recapitulatif — chacun a son lieu de mesure" {
  # ⚠ UN RECAPITULATIF EST UNE SECONDE COPIE. Il derive des qu'une branche de mesure change, et il
  # ment precisement sur le cas rare : celui ou la branche qu'on a oubliee s'execute. La regle se
  # verifie mecaniquement — aucun `p_fact` apres le dernier `p_ok`/`p_warn`/`p_fail` du fichier.
  local dernier_rapport dernier_fait
  dernier_rapport="$(grep -nE '^\s*(p_ok|p_warn|p_fail|p_drift) ' "$MOD" | tail -1 | cut -d: -f1)"
  dernier_fait="$(grep -nE '^\s*p_fact ' "$MOD" | tail -1 | cut -d: -f1)"
  [ "$dernier_fait" -lt "$dernier_rapport" ] \
    || { echo "un p_fact (l.$dernier_fait) suit le dernier rapport (l.$dernier_rapport) : recapitulatif ?" >&2; return 1; }
}
