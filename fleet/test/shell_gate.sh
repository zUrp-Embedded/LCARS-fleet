#!/usr/bin/env bash
# SOURCE: test/shell_gate.sh
# AUTHOR: starfleet
# STARDATE: 2026.239
# STATUS: filet des tests HORS-mix (python + bats des launchers) — le trou que `mix gate` ne voit pas.
#
# RAISON D'ETRE : `mix gate` = compile + `mix test` (ExUnit) + contracts.check. Il ne lance AUCUN
# test shell/python. Un test comme test/test_fleet_mcp_stdio_bridge.py peut donc devenir ROUGE en
# silence (le bridge renomme, le test jamais rejoue) — c'est exactement le bug qui a motive ce filet.
# Ce script est le point d'entree unique des tests hors-mix, cablable dans `mix gate` (cf. mix.exs).
#
# CONTRAT anti-faux-vert :
#   - python3 ABSENT               → ECHEC EXPLICITE (jamais un skip silencieux : c'est la lecon du bug).
#   - 0 test compte OU FAIL>0      → exit != 0 (jamais vert sans compteur positif — la « coquille vide »
#                                     qui passe est l'anti-pattern precis a tuer).
#   - shellcheck                   → HORS GATE depuis le 2026-08-29 (⚖ USER). Le pas est arrive
#                                     rouge et ne l'a jamais quitte ; un gate qu'on sait toujours
#                                     rouge apprend a lire « rouge » comme « normal ». Le code vit
#                                     toujours au §5, sous `LCARS_SHELL_LINT=1`, et son absence est
#                                     ANNONCEE a chaque passage. Contrat d'origine, a restaurer le
#                                     jour ou le compte est a zero : absent ou un seul signalement
#                                     = exit != 0, meme barreau que `--warnings-as-errors`.
#   - bats PRESENT + rouge         → exit != 0.
#   - bats ABSENT                  → PAS d'echec ICI (warning + compte MANQUE). Choix delibere : ce filet
#                                     est cable dans `mix gate`, l'absence de bats sur une machine sans
#                                     bats-core ne doit pas casser le gate de tous. A DURCIR en echec le
#                                     jour ou bats-core est un prerequis pose (installe partout / en CI) :
#                                     passer BATS_MISSING_FATAL=1 (ou flipper le defaut ci-dessous).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LES tests python hors-mix. Une LISTE, pas un chemin : un second fichier pose a cote d'un crochet
# code en dur serait compte comme corpus gate par `lcars.contracts.check` (le dossier `fleet/test`
# y est declare `:gated`) tout en n'etant JAMAIS joue — exactement le defaut que ce registre existe
# pour attraper. Ajouter un test python = ajouter sa ligne ICI, et c'est tout.
PYTESTS=(
  "$HERE/test_fleet_mcp_stdio_bridge.py"
  "$HERE/test_console_deck.py"
  "$HERE/test_uninstructed_commands.py"
  "$HERE/test_catalogue_executor.py"
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
# `fleet/git-hooks/pre-commit`, et un hook a trois modes de defaillance silencieuse, tous mesures :
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
# PERIMETRE : `fleet/` seulement, et c'est un choix ON RECORD. Le reste de l'arbre porte 32
# fichiers non conformes, tous dans `.claude/` (les artefacts de Claude Code lui-meme),
# `docs/#_Archived/` (l'ancien `docs_OBSOLETE/`, deplace au demenagement) ou v1 (supprime par
# l'excommunion, recuperable au tag `v1-excommunication-base`) — gater ces
# trois zones ferait rougir le gate sur du sursis. Le runtime, lui, est a ZERO aujourd'hui : le mur
# se pose sans dette.
# ---------------------------------------------------------------------------
# `REPO_ROOT` est (re)defini ICI et pas plus bas : la premiere version de ce pas le lisait avant sa
# definition, donc `$GO7_HOOK` valait "/fleet/git-hooks/pre-commit", le `-f` echouait, et le pas
# entier se sautait EN SILENCE — un mur pose le matin meme ou j'en fermais six de cette forme.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GO7_HOOK="$REPO_ROOT/fleet/git-hooks/pre-commit"

# ABSENCE = ECHEC DANS UN DEPOT, jamais un saut. Le hook vit DANS le depot : s'il manque la, l'arbre
# est casse, ce n'est pas une fonctionnalite optionnelle. Un `if [[ -f ]]` qui saute rendrait ce pas
# invisible le jour ou il sert le plus.
#
# MAIS UN ARTEFACT N'EST PAS UN DEPOT CASSE. Mesure du 2026-08-07, premier build clean-room apres le
# demenagement : l'etage `build` de l'image copie le perimetre ex-runtime (mix/lib/priv/config/test/
# bin/etc/vendor) et n'embarque ni `fleet/git-hooks/` ni `.git` — deliberement, il n'a pas de hooks a
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
  echo "--- GO-7 : NON VERIFIE ici (fleet/git-hooks absent de cet artefact — contexte hors-depot) ---"
  GO7_SKIPPED=1
fi

if [[ "${GO7_SKIPPED:-0}" != "1" ]]; then

  echo "--- GO-7 : en-tetes declaratifs sous fleet/ ---"
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
      # Pas de branche `ex)` : la clause GO-7 sur les .ex est retiree (2026-08-06). Elle exigeait
      # un tampon `**Last revised**` que la passe 1 du hook ECRIVAIT elle-meme — un mur qui
      # verifiait sa propre peinture. Rien ne la remplace : 238 .ex sur 238 portent un @moduledoc,
      # donc tout marqueur de presence serait vert par construction. Le motif complet est dans
      # l'en-tete du hook, qui reste l'autorite de cette regle.
    esac
  done < <(git -C "$REPO_ROOT" ls-files fleet)

  if [[ ${#GO7_BAD[@]} -gt 0 ]]; then
    echo "ECHEC: GO-7 — ${#GO7_BAD[@]} fichier(s) sans en-tete declaratif sous fleet/ :" >&2
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
TS_TESTS="$HERE/../vendor/token_saver/lcars_tests"
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
#    `fleet/git-hooks/tests/` : meme raison encore. Le pre-commit est le SEUL mur qui s'applique a
#    tout le depot, y compris a lui-meme, et il n'avait aucun test — un mur non teste ne se
#    distingue d'un mur absent que le jour ou on le contourne.
#
#    `fleet/deploy/tests/` : ajoute le 2026-08-05. Ces suites existaient depuis le
#    2026-07-30 et AUCUN gate ne les jouait — un test que personne ne lance est un test qui
#    pourrit, et il donne la couverture sans la donner. Meme raison que les skills : le
#    provisioning est ce qui fabrique la machine sur laquelle tout le reste tourne. Absence du
#    repertoire = pas une erreur (meme regle que les skills).
# ---------------------------------------------------------------------------
# ⚠ `REPO_ROOT` N'EST PAS REDEFINI ICI, ET IL L'ETAIT. La meme derivation vivait deux fois dans ce
# fichier, a l'identique. Sans consequence tant que les deux disent la meme chose — et c'est
# exactement ce qui rend la seconde dangereuse : le jour ou l'une des deux bouge, celle qu'on ne
# relit pas gagne pour la moitie du gate. La definition d'en haut (avec le motif de sa position)
# fait autorite pour tout le fichier.
SKILLS_TESTS="$REPO_ROOT/.claude/skills"
PROVISION_TESTS="$REPO_ROOT/fleet/deploy/tests"
HOOK_TESTS="$REPO_ROOT/fleet/git-hooks/tests"
mapfile -t BATS_FILES < <(
  find "$HERE" -type f -name '*.bats'
  [[ -d "$SKILLS_TESTS" ]] && find "$SKILLS_TESTS" -type f -path '*/tests/*.bats'
  [[ -d "$PROVISION_TESTS" ]] && find "$PROVISION_TESTS" -type f -name '*.bats'
  [[ -d "$HOOK_TESTS" ]] && find "$HOOK_TESTS" -type f -name '*.bats'
  true
)
mapfile -t BATS_FILES < <(printf '%s\n' "${BATS_FILES[@]}" | sort -u)
BATS_FILE_COUNT="${#BATS_FILES[@]}"
# Nombre de cas @test (info plus fine que le nb de fichiers pour l'avertissement « N tests manques »).
if [[ "$BATS_FILE_COUNT" -gt 0 ]]; then
  BATS_TEST_COUNT="$(grep -hcE '^@test' "${BATS_FILES[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
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
# 5) shellcheck sur tout le shell SUIVI. AUCUN filtre de severite.
#
# Le shell entre au meme barreau que l'Elixir, qui compile en `--warnings-as-errors` : un
# signalement, quelle que soit sa severite, est rouge. Un seuil (« sous N erreurs ca passe »)
# fabrique une zone ou l'outil parle et ou personne n'ecoute.
#
# LA LISTE EST CELLE DE GIT, PAS D'UN `find`, et ce n'est pas une commodite : les entrees sans
# extension (`deploy/provision`, `deploy/box`, `bin/lcars`, les hooks) ne se reconnaissent qu'a
# leur shebang, et `fleet/tmp/` porte des scripts fabriques par les suites ExUnit — les auditer
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
# ⚠ PAS D UNE SEULE AFFECTATION : `SC_VERSION="$(command -v shellcheck … && …)"` sous `set -e` TUAIT le script
# quand shellcheck manque — la substitution rend non-zero, l affectation herite du statut, et le gate
# mourait apres « bats : OK » sans une ligne, avant meme d annoncer « HORS GATE ». Mesure sur un
# Ubuntu neuf (banc .63, 2026-08-30) : trois runs rouges de 60-deploy, tests tous verts. La premiere
# commande d une liste `&&` n est pas soumise a errexit ; c est cette forme-la qui survit.
SC_VERSION=""
command -v shellcheck >/dev/null 2>&1 && SC_VERSION="$(shellcheck --version | sed -n 's/^version: //p')"

# ─── LE PAS EST HORS GATE PAR DEFAUT ────────────────────────────────────────────────────────────
#
# ⚖ USER 2026-08-29 : « on ne teste pas un truc qui n'est pas testable ».
#
# Le pas est ARRIVE ROUGE et n'a jamais ete vert : `b4afe7055` l'a cable en annoncant lui-meme sa
# mesure d'atterrissage — 1251 signalements, « la remediation n'est pas dans ce commit ». Un gate
# qu'on sait rouge en permanence ne mesure plus rien : il apprend a lire « rouge » comme « normal »,
# et c'est ainsi qu'un VRAI rouge passe inapercu. Le desactiver est plus honnete que de le laisser
# hurler dans le vide, et plus honnete encore qu'un seuil — un seuil fabriquerait la zone ou l'outil
# parle et ou personne n'ecoute, ce que le commentaire du haut de ce bloc refuse deja.
#
# ⚠ DESACTIVE, PAS SUPPRIME, ET IL LE DIT. Le code reste joue par `LCARS_SHELL_LINT=1` — c'est ce
# que tapera l'agent qui prendra la remediation, fichier par fichier, pour mesurer son avancement.
# Et le pas ANNONCE son absence a chaque passage : un audit qui disparait en silence est un audit
# dont plus personne ne se souvient qu'il a existe.
#
# POUR LE RALLUMER POUR DE BON : remettre `[[ -n "${LCARS_SHELL_LINT:-}" ]] ||` en commentaire ici,
# le jour ou le compte est a zero. Rien d'autre ne bouge.
if [[ -z "${LCARS_SHELL_LINT:-}" ]]; then
  echo "--- shellcheck : HORS GATE (dette connue, ni mesuree ni bloquante ici — LCARS_SHELL_LINT=1 pour l'auditer) ---"
elif [[ -z "$SC_VERSION" ]]; then
  echo "ECHEC: shellcheck absent — $SHELL_FILE_COUNT fichier(s) shell NON audites. Installer : apt install shellcheck." >&2
  GATE_FAIL=1
elif [[ "$SHELL_FILE_COUNT" -eq 0 ]]; then
  # Zero fichier n'est pas un depot sans shell : c'est une decouverte cassee, et elle rendrait vert.
  echo "ECHEC: aucun fichier shell suivi trouve — la decouverte est cassee, pas le depot." >&2
  GATE_FAIL=1
else
  echo "--- shellcheck $SC_VERSION : $SHELL_FILE_COUNT fichier(s) suivi(s), aucun filtre ---"
  set +e
  # ⚠ `-x` N'EST PAS UN FILTRE, C'EST DAVANTAGE D'ANALYSE — il fait SUIVRE les `source`. Sans lui,
  # chaque module rend un SC1091 « Not following » et shellcheck ignore ce que la lib definit ; avec
  # lui il resout `# shellcheck source=../lib/provision-lib.sh`, deja ecrit dans les modules.
  # `--source-path=SCRIPTDIR` est ce qui manquait : ces directives sont relatives au SCRIPT, pas au
  # repertoire d'ou le gate est lance.
  # MESURE sur la liste ci-dessus : 1249 -> 1208 signalements, dont -21 sur le seul rail deploy.
  # AUCUN signalement ajoute : suivre une source ne peut que lever des faux positifs, jamais en creer.
  SC_OUT="$(shellcheck -x --source-path=SCRIPTDIR -f gcc "${SHELL_FILES[@]}" 2>&1)"
  SC_RC=$?
  set -e
  if [[ "$SC_RC" -ne 0 ]]; then
    printf '%s\n' "$SC_OUT" >&2
    echo "ECHEC: shellcheck — $(printf '%s\n' "$SC_OUT" | grep -c ':') signalement(s) sur $(printf '%s\n' "$SC_OUT" | cut -d: -f1 | sort -u | grep -c .) fichier(s)." >&2
    GATE_FAIL=1
  else
    echo "--- shellcheck : OK ($SHELL_FILE_COUNT fichier(s)) ---"
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
