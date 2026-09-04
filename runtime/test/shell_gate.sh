#!/usr/bin/env bash
# SOURCE: test/shell_gate.sh
# AUTHOR: starfleet
# STARDATE: 2026.247
# STATUS: filet des tests HORS-mix (python + bats des launchers) — le trou que `mix gate` ne voit pas.
#
# RAISON D'ETRE : `mix gate` = compile + `mix test` (ExUnit) + contracts.check. Il ne lance AUCUN
# test shell/python. Un test comme test/bin/fleet_mcp_stdio_bridge_test.py peut donc devenir ROUGE en
# silence (le bridge renomme, le test jamais rejoue) — c'est exactement le bug qui a motive ce filet.
# Ce script est le point d'entree unique des tests hors-mix, cablable dans `mix gate` (cf. mix.exs).
#
# CONTRAT anti-faux-vert :
#   - python3 ABSENT               → ECHEC EXPLICITE (jamais un skip silencieux : c'est la lecon du bug).
#   - 0 test compte OU FAIL>0      → exit != 0 (jamais vert sans compteur positif — la « coquille vide »
#                                     qui passe est l'anti-pattern precis a tuer).
#   - shellcheck ABSENT            → ECHEC (meme regle que python3 : un plancher qu'on peut sauter
#                                     en silence n'est pas un plancher).
#   - shellcheck plancher          → `-S warning` sur TOUT le shell suivi, deploy/ compris : un
#                                     signalement de severite >= warning = exit != 0, meme barreau
#                                     que `--warnings-as-errors`. Le plancher est a ZERO (mesure du
#                                     2026-09-01) et mord au premier warning. L'audit complet, toutes
#                                     severites, est opt-in (`LCARS_SHELL_LINT=1`, informatif) — un
#                                     pas qu'on sait toujours rouge apprend a lire « rouge » comme
#                                     « normal » (⚖ USER 2026-08-29), cf. §5.
#   - bats PRESENT + rouge         → exit != 0.
#   - bats ABSENT                  → PAS d'echec ICI (warning + compte MANQUE). Choix delibere : ce filet
#                                     est cable dans `mix gate`, l'absence de bats sur une machine sans
#                                     bats-core ne doit pas casser le gate de tous. A DURCIR en echec le
#                                     jour ou bats-core est un prerequis pose (installe partout / en CI) :
#                                     passer BATS_MISSING_FATAL=1 (ou flipper le defaut ci-dessous).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠ `REPO_ROOT` EST DEFINI EN TETE, UNE SEULE FOIS. Lu avant sa definition, `$GO7_HOOK` vaudrait
# "/fleet/git-hooks/pre-commit", le `-f` echouerait, et le pas GO-7 entier se sauterait EN SILENCE ;
# et `--list-corpora` doit repondre AVANT le premier pas, donc avant que quoi que ce soit ne tourne.
# Une seule definition, au plus haut, pour tout le fichier.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# ─── LES CORPUS QUE CETTE PORTE JOUE — DEFINIS ICI, IMPRIMES A LA DEMANDE ───────────────────────
#
# ⚠ `--list-corpora` NE DECLARE RIEN : il imprime les VARIABLES que la decouverte utilise plus bas.
# Une liste ecrite a cote des chemins reels serait une seconde verite, et c'est precisement le
# defaut que le registre `@test_corpora` (lcars.contracts.check) existe pour attraper — « a corpus
# nobody runs does not rot loudly : it rots while reporting a coverage it does not provide ». Une
# porte qui MENT sur ce qu'elle joue est ce meme defaut, d'un cran plus haut.
#
# ⚠ IL REPOND ET SORT AVANT TOUT PAS : le registre l'interroge, il ne veut pas jouer 205 tests
# python pour obtenir quatre lignes.
#
# ⚠ ET LES CHEMINS SORTENT CANONIQUES. `$HERE/../vendor/...` rendrait « runtime/test/../vendor/… »,
# que le registre compare a « runtime/vendor/… » : deux ecritures du meme repertoire, et une
# comparaison de chaines qui echoue sur une egalite vraie.
#
# ⚠ ET `deploy/tests` N'EST PAS ICI : ses cas sont ceux de L'INSTALLEUR, qui a sa propre porte,
# `deploy/gate.sh`. Le detachement n'est pas declaratif : `pack.sh` joue les deux portes avant d'empaqueter, et
# `tests.corpora_on_record` DEMANDE a chaque porte ce qu'elle joue au lieu de croire un mot-cle.
SKILLS_TESTS="$REPO_ROOT/.claude/skills"
HOOK_TESTS="$REPO_ROOT/runtime/git-hooks/tests"
TS_TESTS="$REPO_ROOT/runtime/vendor/token_saver/lcars_tests"

if [[ "${1:-}" == "--list-corpora" ]]; then
  for _c in "$HERE" "$SKILLS_TESTS" "$HOOK_TESTS" "$TS_TESTS"; do
    [[ -d "$_c" ]] && printf '%s\n' "$(cd "$_c" && pwd)" | sed "s|^$REPO_ROOT/||"
  done
  exit 0
fi

# LES tests python hors-mix. Une LISTE, pas un chemin : un second fichier pose a cote d'un crochet
# code en dur serait compte comme corpus gate par `lcars.contracts.check` (le dossier `runtime/test`
# y est declare `:gated`) tout en n'etant JAMAIS joue — exactement le defaut que ce registre existe
# pour attraper. Ajouter un test python = ajouter sa ligne ICI, et c'est tout.
PYTESTS=(
  "$HERE/bin/fleet_mcp_stdio_bridge_test.py"
  "$HERE/services/console-deck_test.py"
  "$HERE/crosscutting/uninstructed_commands_test.py"
  "$HERE/services/catalogue-executor_test.py"
)

# Politique bats-absent : warning compte (defaut) vs echec dur. Overridable par env pour le jour du
# durcissement, sans re-editer le script. Defaut 0 = warning (cf. contrat ci-dessus).
BATS_MISSING_FATAL="${BATS_MISSING_FATAL:-0}"

GATE_FAIL=0

echo "=== shell_gate : tests hors-mix (python + bats des launchers) ==="

# ---------------------------------------------------------------------------
# 1) Test python du bridge MCP stdio.
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  # python3 absent = le test NE PEUT PAS tourner. On ECHOUE au lieu de sauter en silence : un « pas de
  # python donc on passe » masquerait exactement la classe de bug (test jamais joue) que ce filet attrape.
  echo "ECHEC: python3 absent — impossible de lancer ${PYTESTS[*]} (pas de skip silencieux)." >&2
  exit 1
fi

for f in "${PYTESTS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ECHEC: fichier de test introuvable : $f" >&2
    exit 1
  fi
done

# On capture sortie + code retour SANS que set -e n'avorte le script sur un test rouge (on veut le
# decompte, pas un abandon a la premiere ligne FAIL). Le pire code retour de la serie l'emporte :
# un fichier vert ne doit jamais couvrir un fichier rouge.
set +e
PY_OUT=""
PY_RC=0
for f in "${PYTESTS[@]}"; do
  OUT_ONE="$(python3 "$f" 2>&1)"
  RC_ONE=$?
  PY_OUT="${PY_OUT}${OUT_ONE}"$'\n'
  [[ "$RC_ONE" -ne 0 ]] && PY_RC=$RC_ONE
done
set -e

printf '%s' "$PY_OUT"

# Decompte a partir des lignes emises par check() : « PASS: ... » / « FAIL: ... » (ancre en debut de
# ligne pour ne PAS attraper le « ALL PASS » du verdict). grep -c sort 0 + exit 1 quand rien ne matche
# → `|| true` neutralise le exit sous set -e, la valeur « 0 » reste correcte.
PASS_N="$(printf '%s\n' "$PY_OUT" | grep -c '^PASS: ' || true)"
FAIL_N="$(printf '%s\n' "$PY_OUT" | grep -c '^FAIL: ' || true)"
TOTAL_N=$((PASS_N + FAIL_N))

# ⚠ LE VERDICT PORTE LES SAUTS, SINON UN VERT CACHE CE QUI N'A PAS TOURNE. Ces fichiers annoncent
# deja leurs sauts (« SKIP: … ») quand un outil optionnel manque ; c'est le DECOMPTE qui les
# ignorait, donc la ligne de verdict aussi. Mesure du 2026-08-19 : 145 PASS sur un poste qui a node,
# 124 sur une instance vierge qui ne l'a pas — 21 verifications du JS du deck non jouees, dont
# l'EXECUTION du client de terminal, ajoutee justement parce que `node --check` avait laisse passer
# un ReferenceError fatal. Les deux runs disaient « FAIL=0 », et rien dans le verdict ne distinguait
# « tout a tourne » de « une fonctionnalite entiere n'a pas ete validee ».
#
# On n'ECHOUE PAS dessus : node n'est pas un prerequis declare (cf. `10-packages`, et le Dockerfile
# qui dit le runtime « sans node »). Echouer rendrait le gate rouge sur toute machine CONFORME. La
# regle est celle du reste de ce filet : ce qui n'a pas tourne se DIT, il ne se devine pas.
SKIP_N="$(printf '%s\n' "$PY_OUT" | grep -c '^SKIP: ' || true)"

echo "--- python : PASS=$PASS_N FAIL=$FAIL_N SKIP=$SKIP_N (exit=$PY_RC) ---"
if [[ "$SKIP_N" -gt 0 ]]; then
  printf '%s\n' "$PY_OUT" | grep '^SKIP: ' | sed 's/^/    ⚠ /'
fi

if [[ "$TOTAL_N" -eq 0 ]]; then
  # 0 test compte = coquille vide (fichier casse, import qui plante avant tout check, refactor qui a
  # vide les assertions...). Vert sans compteur positif est INTERDIT : on echoue.
  echo "ECHEC: 0 test python lance (coquille vide) — un gate vert doit avoir un compteur positif." >&2
  GATE_FAIL=1
elif [[ "$FAIL_N" -gt 0 || "$PY_RC" -ne 0 ]]; then
  # FAIL>0 (assertion rouge) OU exit!=0 (crash / verdict d'echec du test) → rouge.
  echo "ECHEC: test python rouge (FAIL=$FAIL_N, exit=$PY_RC)." >&2
  GATE_FAIL=1
fi

# ---------------------------------------------------------------------------
# 1ter) GO-7 sur l'arbre du RUNTIME — le mur que seul un hook tenait.
#
# GO-7 exige un en-tete declaratif sur tout fichier versionne. Il n'etait tenu que par
# `runtime/git-hooks/pre-commit`, et un hook a trois modes de defaillance silencieuse, tous mesures :
# il est OPT-IN par clone (un lot entier est arrive avec 74 fichiers non conformes parce que le
# symlink n'existait pas la-bas) ; `--no-verify` le saute pour TOUS les fichiers du commit, pas
# seulement le fautif ; et un symlink casse fait sauter le hook a git SANS un mot. Il ne voit par
# ailleurs que les fichiers STAGES : ce qui a atterri autrement lui est invisible pour toujours.
#
# ON SOURCE SES PREDICATS, ON NE LES REECRIT PAS. Une version Elixir de cette regle aurait ete un
# second instrument mesurant son souvenir du premier — le defaut exact qu'une sonde de ce depot a
# commis trois fois de suite le 2026-08-06 (marqueur oublie, liste d'exemptions perimee, deux des
# trois formes d'en-tete acceptees). Le hook reste l'autorite ; ce pas le REJOUE sur tout l'arbre.
#
# PERIMETRE : `runtime/` seulement, et c'est un choix ON RECORD. Le reste de l'arbre porte 32
# fichiers non conformes, tous dans `.claude/` (les artefacts de Claude Code lui-meme),
# `docs/#_Archived/` (l'ancien `docs_OBSOLETE/`, deplace au demenagement) ou v1 (supprime par
# l'excommunion, recuperable au tag `v1-excommunication-base`) — gater ces
# trois zones ferait rougir le gate sur du sursis. Le runtime, lui, est a ZERO aujourd'hui : le mur
# se pose sans dette.
# ---------------------------------------------------------------------------
GO7_HOOK="$REPO_ROOT/runtime/git-hooks/pre-commit"

# ABSENCE = ECHEC DANS UN DEPOT, jamais un saut. Le hook vit DANS le depot : s'il manque la, l'arbre
# est casse, ce n'est pas une fonctionnalite optionnelle. Un `if [[ -f ]]` qui saute rendrait ce pas
# invisible le jour ou il sert le plus.
#
# MAIS UN ARTEFACT N'EST PAS UN DEPOT CASSE. Mesure du 2026-08-07, premier build clean-room apres le
# demenagement : l'etage `build` de l'image copie le perimetre ex-runtime (mix/lib/priv/config/test/
# bin/etc/vendor) et n'embarque ni `runtime/git-hooks/` ni `.git` — deliberement, il n'a pas de hooks a
# installer. Ce pas y refusait donc un arbre SAIN, et il cassait le build de l'image entiere.
#
# LE DISCRIMINANT EST UN FAIT, PAS UNE DEVINETTE : `git rev-parse --git-dir` reussit dans un depot et
# echoue dans l'artefact. Et l'absence se DECLARE au lieu de se taire — meme forme que
# `shell.sourcers_set_strict` du contracts.check, qui imprime « NOT CHECKED here (… absent from this
# artifact — runtime-only context) ». Un pas qui saute en silence est le defaut ; un pas qui dit ce
# qu'il n'a pas mesure est une reponse.
if [[ ! -f "$GO7_HOOK" ]]; then
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ECHEC: GO-7 — $GO7_HOOK introuvable dans un DEPOT git (le mur ne peut pas etre rejoue)." >&2
    exit 1
  fi
  echo "--- GO-7 : NON VERIFIE ici (runtime/git-hooks absent de cet artefact — contexte hors-depot) ---"
  GO7_SKIPPED=1
fi

if [[ "${GO7_SKIPPED:-0}" != "1" ]]; then

  echo "--- GO-7 : en-tetes declaratifs sous runtime/ et deploy/ ---"
  eval "$(sed -n '/^is_ipc_exception()/,/^}/p' "$GO7_HOOK")"
  eval "$(sed -n '/^is_evidence_dir()/,/^}/p' "$GO7_HOOK")"
  eval "$(sed -n '/^check_md_header()/,/^}/p' "$GO7_HOOK")"
  eval "$(sed -n '/^check_source_header()/,/^}/p' "$GO7_HOOK")"

  # GARDE D'INSTRUMENT : une extraction vide ferait passer ce pas en mesurant RIEN, et le silence
  # ressemblerait a la conformite. Les quatre predicats doivent exister, sinon on echoue ici.
  for _fn in is_ipc_exception is_evidence_dir check_md_header check_source_header; do
    if ! type "$_fn" >/dev/null 2>&1; then
      echo "ECHEC: GO-7 — predicat '$_fn' non extrait de $GO7_HOOK (le hook a change de forme)." >&2
      exit 1
    fi
  done

  GO7_BAD=()
  while IFS= read -r _f; do
    [[ -f "$REPO_ROOT/$_f" ]] || continue
    is_ipc_exception "$_f" && continue
    is_evidence_dir "$REPO_ROOT/$_f" && continue
    case "${_f##*.}" in
      md) check_md_header "$REPO_ROOT/$_f" || GO7_BAD+=("$_f") ;;
      sh|py) check_source_header "$REPO_ROOT/$_f" || GO7_BAD+=("$_f") ;;
      # Pas de branche `ex)` : aucune clause GO-7 sur les .ex. Un tampon `**Last revised**` que la
      # passe 1 du hook ECRIT elle-meme serait un mur qui verifie sa propre peinture, et 238 .ex sur
      # 238 portent un @moduledoc, donc tout marqueur de presence serait vert par construction. Le
      # motif complet est dans l'en-tete du hook, qui reste l'autorite de cette regle.
    esac
  done < <(git -C "$REPO_ROOT" ls-files fleet deploy)

  if [[ ${#GO7_BAD[@]} -gt 0 ]]; then
    echo "ECHEC: GO-7 — ${#GO7_BAD[@]} fichier(s) sans en-tete declaratif sous runtime/ ou deploy/ :" >&2
    printf '   %s
' "${GO7_BAD[@]}" >&2
    echo "   (le hook pre-commit dit la forme attendue par extension)" >&2
    exit 1
  fi
  echo "--- GO-7 : OK ---"
fi

# ---------------------------------------------------------------------------
# 1bis) Suite LCARS de la brique vendoree token-saver.
#
# C'est le MUR DE L'ANCRAGE AMONT, et il est la seule raison pour laquelle il est gate. La couche
# LCARS ne modifie aucun fichier du sous-arbre vendore (Apache-2.0 §4(b), et la re-copie
# d'update_vendor.sh reste triviale) : elle s'ACCROCHE a des symboles INTERNES du moteur —
# utils._DEFAULT_ERROR_RE, config._load_config, BuildOutputProcessor.process. Aucun ne fait partie
# d'une API publique, donc l'amont peut les renommer sans que ce soit une rupture de son point de
# vue. Sans ce mur, un update romprait les ancrages EN SILENCE : adapter.py continuerait de tourner,
# ses correctifs ne s'appliqueraient plus, et `OOMKilled` redisparaitrait des logs sans qu'un seul
# test ne rougisse.
#
# La suite AMONT (vendor/token_saver/tests/, 7 884 l) n'est deliberement PAS jouee ici : elle
# arbitre les merges amont, update_vendor.sh la joue au moment ou elle sert. Elle est declaree
# {:out, …} au registre des corpus.
# ---------------------------------------------------------------------------
if [[ -d "$TS_TESTS" ]]; then
  if ! python3 -c "import pytest" >/dev/null 2>&1; then
    echo "ECHEC: pytest absent — les lcars_tests de token-saver ne peuvent pas tourner (pas de skip silencieux)." >&2
    exit 1
  fi
  echo "--- token-saver : suite LCARS (ancrage amont) ---"
  set +e
  TS_OUT="$(cd "$HERE/../vendor/token_saver" && python3 -m pytest lcars_tests -q -p no:cacheprovider -o addopts="" 2>&1)"
  TS_RC=$?
  set -e
  echo "$TS_OUT"
  if [[ "$TS_RC" -ne 0 ]]; then
    echo "ECHEC: la suite LCARS de token-saver est ROUGE (exit $TS_RC) — un ancrage amont a lache." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2) Tests bats : les launchers (bwrap_launch, claude_launch) ET les skills du depot. Ranges en
#    sous-dossiers → recherche recursive (pas un simple glob test/*.bats). LE test bats de
#    bwrap_launch ne se contourne pas : s'il est joignable (bats present) il DOIT etre vert.
#
#    Les skills de `.claude/skills/*/tests/` sont inclus parce qu'un skill qui MESURE (le toolkit
#    d'etat de starfleet) est un instrument : non teste, il rapporte des verdicts que rien ne
#    verifie. Le repertoire est hors du runtime, d'ou la seconde recherche ; son absence n'est pas
#    une erreur (un depot sans skills reste valide).
#
#    `runtime/git-hooks/tests/` : meme raison encore. Le pre-commit est le SEUL mur qui s'applique a
#    tout le depot, y compris a lui-meme, et il n'avait aucun test — un mur non teste ne se
#    distingue d'un mur absent que le jour ou on le contourne.
#
#    `deploy/tests/` : PAS ICI. Ce sont les temoins de l'installeur — ils mesurent la chaine
#    d'install, pas le runtime — et `deploy/gate.sh` est leur porte (cf. §0). Une porte qui les
#    compterait annoncerait une couverture que l'autre fournit.
# ---------------------------------------------------------------------------
# ⚠ `REPO_ROOT`, `SKILLS_TESTS` ET `HOOK_TESTS` NE SONT PAS REDEFINIS ICI : ils sont definis en
# tete, avec les autres corpus et le mode `--list-corpora` qui les imprime. Une meme derivation
# ecrite deux fois dans ce fichier serait sans consequence tant que les deux disent la meme chose —
# et c'est exactement ce qui rend la seconde dangereuse : le jour ou l'une bouge, celle qu'on ne
# relit pas gagne pour la moitie du gate. La definition d'en haut fait autorite pour tout le
# fichier.
mapfile -t BATS_FILES < <(
  find "$HERE" -type f -name '*.bats'
  [[ -d "$SKILLS_TESTS" ]] && find "$SKILLS_TESTS" -type f -path '*/tests/*.bats'
  [[ -d "$HOOK_TESTS" ]] && find "$HOOK_TESTS" -type f -name '*.bats'
  true
)
mapfile -t BATS_FILES < <(printf '%s\n' "${BATS_FILES[@]}" | sort -u)
BATS_FILE_COUNT="${#BATS_FILES[@]}"
# Nombre de cas @test (info plus fine que le nb de fichiers pour l'avertissement « N tests manques »).
if [[ "$BATS_FILE_COUNT" -gt 0 ]]; then
  # ⚠ `|| true` LOAD-BEARING (mur I3). `grep -c` rend 1 quand il ne trouve rien, et sous
  # `set -euo pipefail` ce 1 traverse le tube et tue le script. Le cas ne se produit que si AUCUN
  # fichier `.bats` decouvert ne porte de `@test` — une suite videe par un refactor, c'est-a-dire
  # exactement ce qu'un gate doit voir. Meme forme, meme mode de mort dans la porte jumelle
  # (`deploy/gate.sh`), dont le temoin l'a trouve.
  BATS_TEST_COUNT="$( { grep -hcE '^@test' "${BATS_FILES[@]}" 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')"
else
  BATS_TEST_COUNT=0
fi

if [[ "$BATS_FILE_COUNT" -eq 0 ]]; then
  echo "--- bats : aucun fichier .bats trouve sous $HERE (rien a lancer) ---"
elif command -v bats >/dev/null 2>&1; then
  echo "--- bats : $BATS_FILE_COUNT fichier(s), $BATS_TEST_COUNT test(s) launchers+skills+provisioning+hooks — execution ---"

  # ─── L'ENVIRONNEMENT DU LANCEUR N'ENTRE PAS DANS LE VERDICT ────────────────────────────────────
  #
  # Un temoin DECLARE sa premisse, il ne la RECOIT pas. Les SUT de ce depot lisent leurs reglages
  # dans `LCARS_*`, `PROV_*` et `FORGE_*` ; une seule de ces variables presente dans le shell qui
  # lance le gate retune ce que les temoins croient mesurer, et ils rougissent sur du code sain.
  #
  # ⚠ CE N'EST PAS UNE PRECAUTION, C'EST UNE PANNE QUI S'EST PRODUITE TROIS FOIS :
  #   · 2026-08-18 — `provision --env` exporte `FORGE_BASE_URL` (`set -a`) pour tout le run, gate
  #     compris : quatre temoins rouges sur une installation parfaitement saine.
  #   · 2026-08-27 — un `LCARS_SEAT_UID_FILE` pose a la main : huit temoins rouges, dont les deux
  #     GUARD A, sur du code juste.
  #   · 2026-08-27 (fuzz) — `PROV_FLEET_GROUP` retune six temoins. Et cette variable-la VOYAGE :
  #     `64-services` l'ECRIT dans `services.env`, que `fleet_v2` et le convergeur chargent en
  #     `set -a`. Elle est donc dans l'environnement de tout ce qui tourne sur une machine
  #     provisionnee. `LCARS_CONSOLE_GROUP` en retune vingt-huit ; personne ne l'exporte
  #     aujourd'hui, ce qui rend la panne latente et pas moins reelle.
  #
  # Mesure a l'appui : le corpus a ete rejoue sous DIX variables hostiles, une a la fois.
  # Deux ont change le verdict. Le fait qu'il en reste huit sans effet ne dit rien de la onzieme.
  #
  # ON NEUTRALISE, ET ON NOMME CE QU'ON A RETIRE. Un scrub silencieux serait la meme faute d'un cran
  # plus loin : l'operateur qui a pose la variable exprès doit voir qu'elle n'est pas entree.
  # `setup()` reste souverain — chaque temoin exporte ce dont il a besoin, et ca, rien ne l'enleve.
  BATS_ENV=()
  while read -r v; do [[ -n "$v" ]] && BATS_ENV+=(-u "$v"); done < <(
    compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' | sort
  )
  if [[ "${#BATS_ENV[@]}" -gt 0 ]]; then
    echo "--- bats : $(( ${#BATS_ENV[@]} / 2 )) variable(s) du lanceur NEUTRALISEE(S) : ${BATS_ENV[*]//-u/}"
  fi

  set +e
  env "${BATS_ENV[@]}" bats "${BATS_FILES[@]}"
  BATS_RC=$?
  set -e
  if [[ "$BATS_RC" -ne 0 ]]; then
    echo "ECHEC: suite bats rouge (exit=$BATS_RC)." >&2
    GATE_FAIL=1
  else
    echo "--- bats : OK ($BATS_TEST_COUNT test(s)) ---"
  fi
else
  # bats ABSENT : on ne saute pas en silence — on COMPTE les tests non joues et on avertit fort.
  echo "AVERTISSEMENT: bats absent — $BATS_TEST_COUNT test(s) launchers NON executes" \
       "($BATS_FILE_COUNT fichier(s) : les quatre corpus bats (deploy, git-hooks, test, skills)). Installer : apt/brew install bats-core." >&2
  if [[ "$BATS_MISSING_FATAL" != "0" ]]; then
    echo "ECHEC: bats absent et BATS_MISSING_FATAL=$BATS_MISSING_FATAL — durcissement actif." >&2
    GATE_FAIL=1
  fi
fi

# ---------------------------------------------------------------------------
# 5) shellcheck sur tout le shell SUIVI : un PLANCHER (`-S warning`) qui mord, et un AUDIT complet
#    opt-in (`LCARS_SHELL_LINT=1`, toutes severites, informatif).
#
# Le shell entre au meme barreau que l'Elixir, qui compile en `--warnings-as-errors` : un
# signalement de severite >= warning est rouge. Un seuil en NOMBRE (« sous N erreurs ca passe »)
# fabriquerait une zone ou l'outil parle et ou personne n'ecoute ; un seuil de SEVERITE dit ce qu'il
# ne mesure pas, et le reste se lit a la demande.
#
# LA LISTE EST CELLE DE GIT, PAS D'UN `find`, et ce n'est pas une commodite : les entrees sans
# extension (`deploy/provision`, `deploy/box`, `bin/lcars`, les hooks) ne se reconnaissent qu'a
# leur shebang, et `runtime/tmp/` porte des scripts fabriques par les suites ExUnit — les auditer
# reviendrait a auditer la sortie des tests.
#
# ABSENT = ECHEC, jamais un avertissement : c'est un paquet unique, pose en une ligne ici comme en
# CI. Le prerequis est pose des l'entree, sans la periode molle qui a laisse bats en avertissement.
# ---------------------------------------------------------------------------
mapfile -t SHELL_FILES < <(
  git -C "$REPO_ROOT" ls-files -z 2>/dev/null | while IFS= read -r -d $'\0' f; do
    [[ -f "$REPO_ROOT/$f" ]] || continue
    case "$f" in
      *.sh|*.bash|*.bats) printf '%s\n' "$REPO_ROOT/$f"; continue ;;
    esac
    IFS= read -r first < "$REPO_ROOT/$f" || true
    [[ "$first" =~ ^#!.*(bash|[^a-z]sh)([[:space:]]|$) ]] && printf '%s\n' "$REPO_ROOT/$f"
  done
)
SHELL_FILE_COUNT="${#SHELL_FILES[@]}"
# ⚠ PAS D UNE SEULE AFFECTATION : `SC_VERSION="$(command -v shellcheck … && …)"` sous `set -e` TUE le
# script quand shellcheck manque — la substitution rend non-zero, l affectation herite du statut, et
# le gate meurt apres « bats : OK » sans une ligne (mesure sur un Ubuntu neuf, banc .63, 2026-08-30 :
# trois runs rouges de 60-deploy, tests tous verts). La premiere commande d une liste `&&` n est pas
# soumise a errexit ; c est cette forme-la qui survit.
SC_VERSION=""
command -v shellcheck >/dev/null 2>&1 && SC_VERSION="$(shellcheck --version | sed -n 's/^version: //p')"

# LE PLANCHER PORTE SUR TOUT LE SHELL SUIVI, deploy/ COMPRIS, sans exclusion nommee : une exclusion
# « le temps d un chantier » ecrit elle-meme sa condition de sortie et lui survit.
#
# La mesure tient, prise avec l INSTRUMENT DU GATE et non un shellcheck nu :
# `-x --source-path=SCRIPTDIR` suit les `source`, donc il voit les lectures qu un shellcheck seul ne
# relie pas — sans `-x`, trois SC2034 apparaissent dans docker/entrypoint.sh sur des PROV_* que
# provision-lib lit apres le `.`, et ces trois-la n existent pas. Avec l instrument juste : 36
# fichiers shell sous deploy/, ZERO signalement de severite >= warning.
#
# Une exclusion gardee au-dela de sa condition de sortie ne protege plus un chantier : elle soustrait
# un arbre au plancher, et le compte affiche continue de dire « OK » sans nommer ce qu il n a pas lu.
SHELL_FILES_FLOOR=("${SHELL_FILES[@]}")
FLOOR_COUNT="${#SHELL_FILES_FLOOR[@]}"

# ─── LE PLANCHER : `-S warning`, DANS LE GATE ; L'AUDIT COMPLET : OPT-IN ─────────────────────────
#
# ⚖ USER 2026-08-29 : « on ne teste pas un truc qui n'est pas testable ». Un pas qu'on sait rouge en
# permanence ne mesure plus rien : il apprend a lire « rouge » comme « normal », et c'est ainsi
# qu'un VRAI rouge passe inapercu (mesure a l'arrivee du pas : 1251 signalements toutes severites).
# Le desactiver est plus honnete que de le laisser hurler dans le vide, et plus honnete qu'un seuil
# en nombre — qui fabriquerait la zone ou l'outil parle et ou personne n'ecoute.
#
# ⚠ POURQUOI `-S warning` ET PAS LE DEFAUT, et c'est une MESURE, pas un gout. Au defaut (`style`),
# la commande ci-dessous rend 170 signalements sur 21 fichiers, TOUS de severite `note` : entrer la
# rendrait la chaine rouge en permanence. Au seuil `warning` : 0 error, 0 warning au 2026-09-01.
# Le plancher est donc VERT et mord au premier warning introduit. Meme forme que
# `sobelow --exit High` dans `mix.exs`.
#
# Les 170 notes ne sont pas absoutes : elles sont HORS de ce plancher-ci, et se lisent avec
# `LCARS_SHELL_LINT=1` (audit complet, toutes severites, deploy compris).
# ---------------------------------------------------------------------------
if [[ -z "$SC_VERSION" ]]; then
  echo "ECHEC: shellcheck absent — $FLOOR_COUNT fichier(s) shell NON audites. Installer : apt install shellcheck." >&2
  GATE_FAIL=1
elif [[ "$FLOOR_COUNT" -eq 0 ]]; then
  # Zero fichier n'est pas un depot sans shell : c'est une decouverte cassee, et elle rendrait vert.
  echo "ECHEC: aucun fichier shell suivi — la decouverte est cassee, pas le depot." >&2
  GATE_FAIL=1
else
  set +e
  SC_FLOOR="$(shellcheck -x --source-path=SCRIPTDIR -S warning -f gcc "${SHELL_FILES_FLOOR[@]}" 2>&1)"
  SC_FLOOR_RC=$?
  set -e
  if [[ "$SC_FLOOR_RC" -ne 0 ]]; then
    printf '%s\n' "$SC_FLOOR" >&2
    echo "ECHEC: shellcheck plancher — $(printf '%s\n' "$SC_FLOOR" | grep -c ':') signalement(s) de severite >= warning sur $(printf '%s\n' "$SC_FLOOR" | cut -d: -f1 | sort -u | grep -c .) fichier(s)." >&2
    GATE_FAIL=1
  else
    echo "--- shellcheck plancher (-S warning, $FLOOR_COUNT fichier(s), tout le shell suivi) : OK ---"
  fi
fi

# ---------------------------------------------------------------------------
# LE PLANCHER PYTHON. Meme forme que le plancher shellcheck ci-dessus, et pour la meme raison : ce
# depot n'avait AUCUN outillage python — ni ruff, ni flake8, ni config — sur douze fichiers maison
# (bridge MCP, executeurs, deck, et leurs temoins). L'absence totale se remarque avant le contenu.
#
# ⚠ `E9,F` ET RIEN D'AUTRE, et c'est une mesure. Au 2026-09-01 : E9=0, F=0 (les 16 F821 du callback
# git-filter-repo portent leur `noqa` motive, cf. `bin/publish-transform-attribution.py`), mais
# UP=113, S=31, E/W=160. Entrer plus haut rendrait la chaine rouge en permanence — la lecon du
# plancher shell ci-dessus. Le reste se mesure a la demande :
# `ruff check --select UP,S`. Le perimetre et la config vivent dans `pyproject.toml` a la racine.
#
# RUFF ABSENT = ECHEC, jamais un avertissement : meme regle que python3 et shellcheck ci-dessus. Un
# plancher qu'on peut sauter en silence n'est pas un plancher.
# ---------------------------------------------------------------------------
if ! command -v ruff >/dev/null 2>&1; then
  echo "ECHEC: ruff absent — le python maison n'est PAS audite. Installer : pip install ruff (ou apt)." >&2
  GATE_FAIL=1
else
  set +e
  RUFF_OUT="$(cd "$REPO_ROOT" && ruff check --no-cache --output-format=concise 2>&1)"
  RUFF_RC=$?
  set -e
  if [[ "$RUFF_RC" -ne 0 ]]; then
    printf '%s\n' "$RUFF_OUT" >&2
    echo "ECHEC: ruff plancher — $(printf '%s\n' "$RUFF_OUT" | grep -c ':') signalement(s) E9/F." >&2
    GATE_FAIL=1
  else
    echo "--- ruff plancher (E9,F — vendor exclu) : OK ---"
  fi
fi

# ---------------------------------------------------------------------------
# L'AUDIT COMPLET, opt-in : toutes severites, deploy compris, informatif.
# ---------------------------------------------------------------------------
if [[ -n "${LCARS_SHELL_LINT:-}" ]]; then
  if [[ -z "$SC_VERSION" ]]; then
    echo "--- shellcheck : audit demande mais binaire absent ---" >&2
  else
    echo "--- shellcheck $SC_VERSION : audit complet, $SHELL_FILE_COUNT fichier(s), aucun filtre ---"
    set +e
    SC_OUT="$(shellcheck -x --source-path=SCRIPTDIR -f gcc "${SHELL_FILES[@]}" 2>&1)"
    SC_RC=$?
    set -e
    printf '%s\n' "$SC_OUT"
    echo "--- audit : $(printf '%s\n' "$SC_OUT" | grep -c ':') signalement(s), rc=$SC_RC (informatif, hors plancher) ---"
  fi
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "=== shell_gate : PASS=$PASS_N FAIL=$FAIL_N SKIP=$SKIP_N (python) | bats=$BATS_TEST_COUNT test(s) $(command -v bats >/dev/null 2>&1 && echo joues || echo MANQUES) ==="
if [[ "$GATE_FAIL" -ne 0 ]]; then
  echo "=== shell_gate : ECHEC ==="
  exit 1
fi
echo "=== shell_gate : VERT ==="
exit 0
