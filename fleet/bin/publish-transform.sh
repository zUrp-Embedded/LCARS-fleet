#!/usr/bin/env bash
# SOURCE: bin/publish-transform.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-07
# STATUS: PROTO-V1 — publish transform: rewrites a forge clone's history for an EXTERNAL mirror
#   Options: --vendor-identity FILE (default: bin/claude_launch.identity, co-located with the active N1
#            launcher — NAME=/EMAIL=) · --filter-repo-bin BIN (default: git-filter-repo on PATH, or
#            $FILTER_REPO_BIN) · --system-email EMAIL (default: system_starfleet@lcars.local — MUST match
#            Fleet.Credentials.ForgeIdentity.system_email/0, the single authority runtime-side).
#
# EXIT CODES, as they actually are — this runs under `set -euo pipefail` with no trap, so most failures
# propagate the exit status of the command that failed, they are NOT normalised:
#   0   the rewritten clone is ready in --out
#   4   --linearize failed its postconditions (final tree differs, or a merge survived) — do not push
#   1   usage, unreadable token/identity file, --out already exists, or git-filter-repo missing
#   2   ONE case only: no non-system commit in the clone, so the human cannot be derived (the pre-scan)
#   *   anything else is the failing command's own status — `git clone` returns git's (128 on the usual
#       clone errors), the filter-repo subshell returns filter-repo's. Do not read a non-2 failure as
#       "not a clone/filter-repo problem": it is the opposite.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE=""
REPO=""
TOKEN_FILE=""
OUT_DIR=""
VENDOR_IDENTITY="$SCRIPT_DIR/claude_launch.identity"
FILTER_REPO_BIN="${FILTER_REPO_BIN:-git-filter-repo}"
SYSTEM_EMAIL="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}@lcars.local"
# D2 — branche à APLATIR en first-parent après la transformation (forme MR canonique, cf. la
# fonction). Vide = off : le miroir publie l'historique tel quel, bulles comprises — elles sont
# normales sur un main, des deux cotes ; l'aplatissement ne sert que la branche d'une MR upstream (D3).
LINEARIZE=""

usage() {
  echo "Usage: $0 --repo OWNER/NAME --forge URL --token-file FICHIER --out DIR [options]" >&2
  echo "  Options: --vendor-identity F · --filter-repo-bin B · --system-email E · --linearize BRANCHE" >&2
  exit 1
}

# THE VOCABULARY OF INTERNAL ATTRIBUTION, WRITTEN ONCE AND READ FROM BOTH ENDS.
# The same two patterns decide what gets REWRITTEN (the boundary, below) and what gets REFUSED (the
# certification, here). One function each, one source of truth: if a new form of internal
# attribution appears tomorrow, both ends learn it at the same instant. A boundary that drifted from
# the certification would select less than the certification refuses — which is a publish that dies
# at the last gate instead of one that never had the marker.
internal_ident_re() { # <system_email>
  printf '@lcars\.local|%s' "$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')"
}
# ⚠ `\s` ET NON `[[:space:]]`, parce que ce motif est lu par DEUX moteurs. La classe POSIX est
# valide en ERE (grep) et n'existe PAS en Python, qui la lit comme un ensemble imbrique et emet un
# `FutureWarning` sur stderr — lequel s'est retrouve melange a la sortie de la fonction et a fait
# rougir quatre temoins pour une raison qui n'etait pas la leur. `\s` est compris des deux.
# Le prix d'une source unique est qu'elle doit parler la langue de tous ses lecteurs.
internal_msg_re() { printf 'Co-authored-by:\s*LCARS-|@lcars\.local'; }

scan_forbidden_markers() {
  local dir="$1" system_email="$2" hits=0

  local ident
  ident="$(cd "$dir" && git log --all --format='%ae%n%ce' | grep -iE "$(internal_ident_re "$system_email")" || true)"
  if [[ -n "$ident" ]]; then
    echo "publish-transform: CERTIFICATION KO — identite interne survivante dans author/committer :" >&2
    printf '  %s\n' "$ident" >&2
    hits=1
  fi

  local trailer
  trailer="$(cd "$dir" && git log --all --format='%B' | grep -iE "$(internal_msg_re)" || true)"
  if [[ -n "$trailer" ]]; then
    echo "publish-transform: CERTIFICATION KO — trailer interne survivant dans les messages :" >&2
    printf '  %s\n' "$trailer" >&2
    hits=1
  fi

  return "$hits"
}

# LA BORNE — definie ICI, avant le garde de sourcing, pour la meme raison que ses voisines : la
# suite bats source ce fichier pour piloter ses fonctions une par une, et ce qui vit apres le garde
# n'existe pas pour elle. Une fonction non testable est une fonction dont on croit le comportement.
oldest_internal_commit() { # <dir> <system_email> -> sha, or empty
  (cd "$1" && git log --topo-order --reverse --format='%H%x1f%ae%x1f%ce%x1f%B%x1e' HEAD) \
    | LCARS_IDENT_RE="$(internal_ident_re "$2")" LCARS_MSG_RE="$(internal_msg_re)" python3 -c '
import os, re, sys
ident = re.compile(os.environb[b"LCARS_IDENT_RE"], re.I)
msg = re.compile(os.environb[b"LCARS_MSG_RE"], re.I)
# ⚠ `maxsplit=3` ET PAS UN SPLIT NU : le body est le DERNIER champ et un message de commit peut
# contenir nimporte quel octet, `\x1f` compris. Un split nu rendait alors plus de quatre champs et
# `f[3]` ne portait que la premiere tranche — un marqueur interne place apres restait invisible a
# la borne. Avec `maxsplit=3`, tout ce qui suit le troisieme separateur EST le body.
#
# ANGLE MORT DECLARE : un `\x1e` dans un body coupe le RECORD, pas le champ, et la borne rate ce
# commit. Aucun format de `git log` ne prefixe ses longueurs, donc aucun separateur ne peut etre sur.
# La direction reste SURE : la certification rescanne toute lhistoire, voit le marqueur, et REFUSE.
# On perd une publication, on ne laisse jamais fuir une attribution interne.
for rec in sys.stdin.buffer.read().split(b"\x1e"):
    f = rec.strip(b"\n").split(b"\x1f", 3)
    if len(f) < 4:
        continue
    sha, ae, ce, body = f[0], f[1], f[2], f[3]
    if ident.search(ae) or ident.search(ce) or msg.search(body):
        sys.stdout.write(sha.decode())
        break
'
}

# POSTCONDITIONS, both fail-loud: the new tip's tree is BYTE-IDENTICAL to the old one, and no merge
# commit remains.
linearize_first_parent() { # <dir> <branch>
  local dir="$1" branch="$2" prev="" new c old_tip
  old_tip="$(git -C "$dir" rev-parse "refs/heads/${branch}" 2>/dev/null)"     || { echo "publish-transform: --linearize: branche inconnue: $branch" >&2; return 1; }

  while IFS= read -r c; do
    new="$(
      GIT_AUTHOR_NAME="$(git -C "$dir" log -1 --format=%an "$c")"       GIT_AUTHOR_EMAIL="$(git -C "$dir" log -1 --format=%ae "$c")"       GIT_AUTHOR_DATE="$(git -C "$dir" log -1 --format=%aD "$c")"       GIT_COMMITTER_NAME="$(git -C "$dir" log -1 --format=%cn "$c")"       GIT_COMMITTER_EMAIL="$(git -C "$dir" log -1 --format=%ce "$c")"       GIT_COMMITTER_DATE="$(git -C "$dir" log -1 --format=%cD "$c")"       git -C "$dir" commit-tree "$c^{tree}" ${prev:+-p "$prev"}         < <(git -C "$dir" log -1 --format=%B "$c")
    )" || return 1
    prev="$new"
  done < <(git -C "$dir" rev-list --first-parent --reverse "$old_tip")

  [[ "$(git -C "$dir" rev-parse "$prev^{tree}")" == "$(git -C "$dir" rev-parse "$old_tip^{tree}")" ]]     || { echo "publish-transform: linearize: l arbre final DIFFERE de l original — refus" >&2; return 1; }

  git -C "$dir" update-ref "refs/heads/${branch}" "$prev"

  if [[ -n "$(git -C "$dir" rev-list --merges "refs/heads/${branch}")" ]]; then
    echo "publish-transform: linearize: un commit de merge survit — refus" >&2
    return 1
  fi
}

# Source guard (standard idiom): sourcing loads the functions WITHOUT running the transform — the bats
# suite drives scan_forbidden_markers AND linearize_first_parent directly on fixture repos, without
# git-filter-repo.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --forge) FORGE="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --vendor-identity) VENDOR_IDENTITY="$2"; shift 2 ;;
    --filter-repo-bin) FILTER_REPO_BIN="$2"; shift 2 ;;
    --system-email) SYSTEM_EMAIL="$2"; shift 2 ;;
    --linearize) LINEARIZE="$2"; shift 2 ;;
    *) echo "publish-transform: option inconnue: $1" >&2; usage ;;
  esac
done

[[ -n "$REPO" && -n "$FORGE" && -n "$TOKEN_FILE" && -n "$OUT_DIR" ]] || usage
[[ -r "$TOKEN_FILE" ]] || { echo "publish-transform: token-file illisible: $TOKEN_FILE" >&2; exit 1; }
[[ -e "$OUT_DIR" ]] && { echo "publish-transform: --out ($OUT_DIR) n'est pas un chemin neuf — filter-repo exige un clone FRAIS" >&2; exit 1; }

command -v "$FILTER_REPO_BIN" >/dev/null 2>&1 || {
  echo "publish-transform: git-filter-repo introuvable ($FILTER_REPO_BIN)." >&2
  echo "  Installe-le dans un venv (PEP 668 bloque le pip global) :" >&2
  echo "    python3 -m venv ~/.venvs/git-filter-repo && ~/.venvs/git-filter-repo/bin/pip install git-filter-repo" >&2
  echo "  Puis relance avec --filter-repo-bin ~/.venvs/git-filter-repo/bin/git-filter-repo" >&2
  exit 1
}

[[ -r "$VENDOR_IDENTITY" ]] || { echo "publish-transform: fichier vendor illisible: $VENDOR_IDENTITY" >&2; exit 1; }
# shellcheck source=/dev/null
source "$VENDOR_IDENTITY"
[[ -n "${NAME:-}" && -n "${EMAIL:-}" ]] || { echo "publish-transform: $VENDOR_IDENTITY doit poser NAME= et EMAIL=" >&2; exit 1; }
VENDOR_NAME="$NAME"
VENDOR_EMAIL="$EMAIL"

TOKEN="$(<"$TOKEN_FILE")"

echo "publish-transform: clone frais $FORGE/$REPO.git → $OUT_DIR"
# Header auth (NEVER the token in the URL or argv — the same mechanism as
# Fleet.Credentials.ForgeAuth.git_env: GIT_CONFIG_KEY/VALUE rather than https://<token>@host, so the
# token does not leak through /proc/<pid>/cmdline).
GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.${FORGE}.extraheader" \
  GIT_CONFIG_VALUE_0="Authorization: token ${TOKEN}" \
  git clone "$FORGE/$REPO.git" "$OUT_DIR"

# ⚠ `awk '… {print; exit}'` TUE CE SCRIPT SUR TOUT DEPOT REEL, et aucune fixture ne pouvait le
# montrer. `exit` ferme le tuyau des la premiere ligne retenue ; si `git log` ecrit encore — ce qui
# est le cas des que la sortie depasse le tampon de pipe, ~64 Ko — il recoit SIGPIPE, `pipefail`
# remonte 141, et `set -e` abat le script juste apres le clone. Mesure du 2026-08-20 sur
# jquery/jquery : 8489 commits -> exit 141 ; les 3 premiers du meme depot -> exit 0. Toutes les
# fixtures du depot font une poignee de commits, donc toutes passaient.
# ⚠ « INTERNE » EST UN DOMAINE, PAS UNE ADRESSE — et ce filtre n'excluait qu'une adresse.
# `system_starfleet` n'est qu'UN des comptes internes : les neuf roles (`system_chief`,
# `fleet_engineer`, `fleet_scribe`...) authorent tous en `<login>@lcars.local`. Un depot dont le
# premier committer non-starfleet etait `system_chief@lcars.local` elisait donc un COMPTE INTERNE
# comme « l humain », et le substituait partout. La certification l aurait rattrape — en accusant
# une identite survivante, alors que la cause aurait ete une identite mal CHOISIE.
# ── L IDENTITE DECLAREE D ABORD, LE RENIFLAGE EN REPLI ──────────────────────────────────────────
# L humain de la boite a DECLARE une identite git (`70-human.sh`, semee une fois depuis son compte
# forge et jamais reecrite). La prendre supprime un TIRAGE : le reniflage ci-dessous rend la
# premiere identite non-interne que `git log --all` veut bien sortir, et sur un depot a quatre
# adresses humaines historiques le resultat depend de l ordre du log, pas d une decision.
#
# Le repli reste necessaire : un depot importe d ailleurs peut n avoir aucune identite declaree
# sous la main (transform joue hors de la boite, banc, outil lance a la main).
# ⚠ `--global`, ET PAS `--get` NU. Sans lui, git resout local > global : lance depuis un depot qui
# porte un `[user]` local, le script prendrait CETTE identite au lieu de celle que la boite a
# declaree — la seule que le commentaire ci-dessus invoque.
HUMAN_NAME="$(git config --global --get user.name 2>/dev/null || true)"
HUMAN_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"

# ⚠ UNE IDENTITE DECLAREE INTERNE NE VAUT PAS MIEUX QUE PAS D IDENTITE. Un pod, ou une boite dont
# le git global porte un compte de role, tomberait sinon dans le cas que toute cette passe existe
# pour supprimer — et la certification refuserait apres coup, en accusant l historique.
if [[ -z "$HUMAN_EMAIL" || "$HUMAN_EMAIL" == *"@lcars.local" ]]; then
  HUMAN_LINE="$(cd "$OUT_DIR" && git log --all --format='%cn|%ce' | awk -F'|' '$2 !~ /@lcars\.local$/ && !seen {print; seen=1}')"
  [[ -n "$HUMAN_LINE" ]] || { echo "publish-transform: aucune identite git declaree, et tous les commits sont a des comptes internes (@lcars.local) — l'humain reste inconnu" >&2; exit 2; }
  HUMAN_NAME="${HUMAN_LINE%%|*}"
  HUMAN_EMAIL="${HUMAN_LINE##*|}"
  echo "publish-transform: identite humaine DEDUITE de l historique ($HUMAN_NAME <$HUMAN_EMAIL>) — aucune n etait declaree"
else
  echo "publish-transform: identite humaine DECLAREE ($HUMAN_NAME <$HUMAN_EMAIL>)"
fi
[[ -n "$HUMAN_NAME" ]] || HUMAN_NAME="$HUMAN_EMAIL"

# AND THE SAFETY IS FREE: the boundary selects, the certification then rescans the WHOLE history. A
# boundary computed too high leaves an internal marker below it, and the certification REFUSES. A
# wrong boundary cannot leak; it can only stop the publish.

FIRST_OURS="$(oldest_internal_commit "$OUT_DIR" "$SYSTEM_EMAIL")"
REFS_ARGS=()
if [[ -z "$FIRST_OURS" ]]; then
  echo "publish-transform: aucune attribution interne — rien a reecrire, tous les SHA conserves"
elif BOUND="$(git -C "$OUT_DIR" rev-parse -q --verify "${FIRST_OURS}^" 2>/dev/null)" && [[ -n "$BOUND" ]]; then
  REFS_ARGS=(--refs "${BOUND}..HEAD")
  echo "publish-transform: reecriture BORNEE a ${FIRST_OURS:0:8}..HEAD ($(git -C "$OUT_DIR" rev-list --count "${BOUND}..HEAD") commits) — l histoire importee garde ses SHA"
else
  # Our oldest commit IS the root: the whole history is ours, so the whole history is rewritten.
  echo "publish-transform: tout l historique est interne (projet ne dans la fleet) — reecriture complete"
fi

if [[ -n "$FIRST_OURS" ]]; then
echo "publish-transform: passe filter-repo — toute identite interne (@lcars.local) devient $HUMAN_NAME, co-author interne devient $VENDOR_NAME"
# The 5 values cross through the ENVIRONMENT (os.environb, callback side), NEVER through bash
# interpolation into the Python source: an author name is UNCONTROLLED data (git log %cn), and the old
# `${VAR@Q}` produced, on an apostrophe (O'Brien), a bash literal `$'...'` that is INVALID Python —
# a git-filter-repo SyntaxError and an opaque exit 2. The callback is FIXED text (bash single quotes, no
# apostrophe inside it); `os.environb` yields the exact bytes (no decode/re-encode, non-UTF-8 names ok).
(cd "$OUT_DIR" && \
  LCARS_PUB_VENDOR_NAME="$VENDOR_NAME" \
  LCARS_PUB_VENDOR_EMAIL="$VENDOR_EMAIL" \
  LCARS_PUB_HUMAN_NAME="$HUMAN_NAME" \
  LCARS_PUB_HUMAN_EMAIL="$HUMAN_EMAIL" \
  "$FILTER_REPO_BIN" --commit-callback '
import re, os
VENDOR_NAME = os.environb[b"LCARS_PUB_VENDOR_NAME"]
VENDOR_EMAIL = os.environb[b"LCARS_PUB_VENDOR_EMAIL"]
HUMAN_NAME = os.environb[b"LCARS_PUB_HUMAN_NAME"]
HUMAN_EMAIL = os.environb[b"LCARS_PUB_HUMAN_EMAIL"]

# INTERNAL IS THE DOMAIN, and it must be the SAME question the certification asks. This keyed on
# one address (SYSTEM_EMAIL) while the certification refuses on `@lcars.local`: the rewrite and its
# guard did not mean the same thing by internal, and the guard was the one telling the truth.
# Measured 2026-08-21 on a real project: 3 survivors out of 8 commits, in two shapes the address
# test cannot see - an author on another internal account (system_chief), and a HUMAN author whose
# COMMITTER was internal. The second one this callback never even looked at.
# CASE-FOLDED, because the certification greps case-insensitively. Leaving the two apart would let
# a `@LCARS.local` through the rewrite and straight into the refusal - blocked, never leaked, but
# with a clone the script itself is unable to clean.
def internal(email):
    return email.lower().endswith(b"@lcars.local")

# ⚠ THE SIDES ARE READ BEFORE EITHER IS WRITTEN, and re-reading them would not be a style question.
# The second block used to test the LIVE `commit.author_email`; for an author AND committer both
# internal, the first block had already replaced the author, so the second one took the branch that
# means "the author is external and is the same person who committed" - on a commit where that is
# false. The value produced was right and the reason was wrong, which is the shape a later refactor
# trusts and breaks.
# NB: this block is a single-quoted bash string -> NO ASCII apostrophe here (one would close the
# quote - the exact bug class the env-var passing fixes).
author_was_internal = internal(commit.author_email)
committer_was_internal = internal(commit.committer_email)

# EACH SIDE IS DECIDED ON ITS OWN, and an internal side never falls back on the other side, which
# may be internal as well. Copying an internal committer into the author - what the old fallback did
# whenever the committer merely was not starfleet - moved the leak instead of closing it.
if author_was_internal:
    if not committer_was_internal:
        commit.author_name = commit.committer_name
        commit.author_email = commit.committer_email
    else:
        commit.author_name = HUMAN_NAME
        commit.author_email = HUMAN_EMAIL

if committer_was_internal:
    if not author_was_internal:
        # The author was already external and is the same person who committed through the system.
        # Falling back to the repo-wide human here would attribute the commit to somebody else.
        commit.committer_name = commit.author_name
        commit.committer_email = commit.author_email
    else:
        commit.committer_name = HUMAN_NAME
        commit.committer_email = HUMAN_EMAIL

# THE DOMAIN HERE TOO. Anchoring on the `LCARS-` prefix made this pattern a bet on the commit gate
# always shaping the trailer that way; a co-author written `system_chief <system_chief@lcars.local>`
# escaped the rewrite and was caught by the certification instead - blocked, and unfixable by the
# very pass meant to fix it. The address inside the angle brackets is the fact; the name is not.
commit.message = re.sub(
    rb"Co-authored-by:\s*[^<\n]*<[^>]+@lcars\.local>",
    b"Co-Authored-By: " + VENDOR_NAME + b" <" + VENDOR_EMAIL + b">",
    commit.message,
    flags=re.IGNORECASE,
)
' ${REFS_ARGS[@]+"${REFS_ARGS[@]}"})
fi

# ⚠ `--partial` LAISSE `refs/remotes/origin/*` SUR L'HISTOIRE D'AVANT, et filter-repo le documente
# ("no automatic remapping of refs/remotes/origin/* to refs/heads/*"). La certification, elle, lit
# `git log --all` — donc elle voyait l'attribution interne survivre dans des refs QUI NE SONT PAS
# PUBLIEES, et refusait une passe pourtant propre. Mesure du 2026-08-20 : HEAD portait 0 marqueur,
# `--all` en portait 3, tous derriere `origin/*`.
git -C "$OUT_DIR" remote remove origin 2>/dev/null || true

if [[ -n "$LINEARIZE" ]]; then
  echo "publish-transform: linearisation first-parent de '$LINEARIZE' (forme MR — arbre final identique, merges aplatis)"
  linearize_first_parent "$OUT_DIR" "$LINEARIZE" || exit 4
fi

# CERTIFY the transform instead of trusting its exit code (see scan_forbidden_markers). A surviving
# internal marker = a broken publish that would leak the internal attribution outside — refuse loud
# (exit 3), the clone is left in place for inspection.
if ! scan_forbidden_markers "$OUT_DIR" "$SYSTEM_EMAIL"; then
  echo "publish-transform: ARRET — le clone transforme porte encore une attribution interne (voir ci-dessus)." >&2
  echo "  Le clone est laisse dans $OUT_DIR pour inspection ; NE PAS pousser en l'etat." >&2
  exit 3
fi

echo ""
echo "publish-transform: fin de la passe → $OUT_DIR (certifie : zero attribution interne survivante)"
echo "  Les SHA des commits REECRITS sont neufs (passe one-way : ce n'est PAS un sync avec la forge)."
echo "  Ceux de l'histoire importee sont CONSERVES — c'est ce qui rend une PR vers l'upstream lisible."
echo "  Geste de publish (ce script ne pousse JAMAIS — le push est ton geste) :"
echo "    cd $OUT_DIR"
echo "    git remote add <nom> <url-du-depot-de-destination>"
echo "    git push <nom> main"
echo "  Ou, si le projet est deja lie : « lcars publish run <owner/nom-interne> » — le rail"
echo "  pousse une branche roulante et ouvre UNE PR/MR, sans toucher la base." 
