#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/lib.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — primitives partagees par toutes les sondes
#
# Shared primitives for the `state_of_the_fleet` probes. Sourced, never executed.
#
# WHY CODE AND NOT PROSE: a probe described in markdown is re-invented at every run — that is an
# impression, not a measurement. Two runs of this file are comparable; two readings of a paragraph
# are not. Comparability is the precondition for saying "this changed since earlier".
#
# THE OUTPUT CONTRACT (one JSON object per line, stdout):
#   probe            dotted id, stable across runs
#   plane            instruments | fleet | pods | forge | projects | self
#   verdict          operational | inactive | degraded | unreachable | unknown
#   vantage          local | reseau | hote-http | hote-socket
#   method           the exact command, so the reader can re-run it
#   evidence         verbatim, trimmed, NEVER paraphrased
#   cannot_conclude  what this probe does NOT prove — MANDATORY
#   ts               UTC
#
# `unreachable` is NOT `degraded`. If curl is missing, the fleet is not degraded — WE ARE BLIND.
# Conflating the two is the exact lie this tool exists to prevent. Same reason `unknown` exists:
# an anonymous 404 on a forge org does not distinguish absent from not-visible, and a probe that
# resolves that ambiguity on its own is inventing a fact.
#
# Return codes follow `provision doctor` (house convention, do not diverge):
#   0 conforme · 1 drift · 2 erreur-de-sonde
#
# Language: comments EN (source prose), emitted strings FR WITHOUT ACCENTS (the output is grepped
# from a source tree, cf. the shell-CLI rule in fleet/runtime/CLAUDE.md).

set -uo pipefail   # NO -e: a probe that fails must EMIT its failure, not abort the run.

# ── Verdict tallies. The runner reads them to compute its exit code. ──────────────────────────────
SOTF_OK=0 SOTF_DRIFT=0 SOTF_ERROR=0 SOTF_UNKNOWN=0

# ── emit <probe> <plane> <verdict> <vantage> <method> <evidence> <cannot_conclude> ────────────────
# One line of JSON. Built with jq so a quote, a newline or a UTF-8 byte in the evidence cannot
# break the format — evidence is verbatim by contract, and verbatim means untrusted as a string.
# If jq is absent the whole contract is void, so we say so once, loudly, on stderr and keep going
# with a degraded plain-text line: a blind run must still report, never die silently.
emit() {
  local probe="$1" plane="$2" verdict="$3" vantage="$4" method="$5" evidence="$6" cannot="$7"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  case "$verdict" in
    operational|inactive) SOTF_OK=$((SOTF_OK + 1)) ;;
    degraded)             SOTF_DRIFT=$((SOTF_DRIFT + 1)) ;;
    unreachable)          SOTF_ERROR=$((SOTF_ERROR + 1)) ;;
    unknown)              SOTF_UNKNOWN=$((SOTF_UNKNOWN + 1)) ;;
    *) echo "sotf: verdict invalide '$verdict' pour $probe (bug de sonde)" >&2; SOTF_ERROR=$((SOTF_ERROR + 1)) ;;
  esac

  # `cannot_conclude` is mandatory BY CONTRACT: a probe that cannot state its interpretation limit
  # does not belong here. Refused loudly rather than emitted empty — an empty limit reads as "this
  # proves everything", which is the claim we never want to make by omission.
  if [[ -z "$cannot" ]]; then
    echo "sotf: $probe n'a pas declare cannot_conclude (contrat viole)" >&2
    cannot="(non declare — bug de sonde)"
  fi

  if [[ -n "${SOTF_HAS_JQ:-}" ]]; then
    jq -cn \
      --arg probe "$probe" --arg plane "$plane" --arg verdict "$verdict" --arg vantage "$vantage" \
      --arg method "$method" --arg evidence "$evidence" --arg cannot "$cannot" --arg ts "$ts" \
      '{probe:$probe,plane:$plane,verdict:$verdict,vantage:$vantage,method:$method,evidence:$evidence,cannot_conclude:$cannot,ts:$ts}'
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$probe" "$verdict" "$vantage" "$evidence" "$cannot"
  fi
}

# ── have <cmd> — is a tool present ────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# ── trim <text> [max] — evidence is verbatim, but bounded ─────────────────────────────────────────
# A probe's evidence must be quotable, not a dump. Truncation is MARKED so a reader never mistakes a
# cut for the whole answer.
trim() {
  local txt="$1" max="${2:-400}"
  txt="${txt//$'\r'/}"
  if [[ "${#txt}" -gt "$max" ]]; then
    printf '%s… (tronque a %s car.)' "${txt:0:$max}" "$max"
  else
    printf '%s' "$txt"
  fi
}

# ── Port resolution ───────────────────────────────────────────────────────────────────────────────
# `bin/fleet_v2` derives a per-human port block from the UID: base = 21000 + (uid % 500) * 10, then
# API = base, observation = base+1. We re-derive it rather than hardcode, because two humans on one
# box get two blocks and a hardcoded 21000 would silently probe the neighbour's fleet.
#
# LCARS_API_URL / LCARS_OBS_URL WIN when set. They are not injected into a pod today (measured on a
# live starfleet: neither var is in its env) — the day the launcher passes them, this function stops
# guessing without a line changing here. Guessing from the UID is correct only while the pod
# inherits the human's UID, which is the current spawn model, not a law.
sotf_uid() { id -u; }

sotf_port_base() {
  local uid; uid="$(sotf_uid)"
  echo $(( 21000 + (uid % 500) * 10 ))
}

# The runtime dir a started fleet leaves behind. Its EXISTENCE is the discriminator between "no
# fleet was ever started here" and "a fleet is started and unwell" — measured on two specimens: a
# live box has `~/.lcars/run/{api.sock,api_url,fleet_v2.sock,mcp,tmux-sock}`, a fresh container has
# no `run/` at all. Without it, a box that was never started reports `degraded` on every endpoint,
# which is a false alarm dressed as a finding.
sotf_run_dir() { echo "${LCARS_RUN_DIR:-$HOME/.lcars/run}"; }
sotf_fleet_ever_started() { [[ -d "$(sotf_run_dir)" ]]; }

# `bin/fleet_v2` WRITES the API url it computed into `~/.lcars/run/api_url` (line 125). That file is
# the fleet's own answer to "where am I listening", and it beats deriving from the UID: the
# derivation only holds while the reader shares the launcher's UID, which a pod does today and is
# not a law. Order: env (explicit operator override) > the fleet's own file > derivation.
sotf_api_url() {
  if [[ -n "${LCARS_API_URL:-}" ]]; then echo "${LCARS_API_URL%/}"; return; fi
  local f; f="$(sotf_run_dir)/api_url"
  if [[ -r "$f" ]]; then local u; u="$(head -1 "$f" 2>/dev/null)"; [[ -n "$u" ]] && { echo "${u%/}"; return; }; fi
  echo "http://127.0.0.1:$(sotf_port_base)"
}

# No `obs_url` file is written by the launcher today, so the observation port is derived from the
# API one when that came from a file (base+1, the launcher's own block layout), else from the UID.
sotf_obs_url() {
  if [[ -n "${LCARS_OBS_URL:-}" ]]; then echo "${LCARS_OBS_URL%/}"; return; fi
  local api port; api="$(sotf_api_url)"; port="${api##*:}"
  if [[ "$port" =~ ^[0-9]+$ ]]; then echo "${api%:*}:$(( port + 1 ))"; else echo "http://127.0.0.1:$(( $(sotf_port_base) + 1 ))"; fi
}

# How the URL was obtained — a reader must be able to tell a declared endpoint from a guessed one,
# because a wrong guess probes the NEIGHBOUR's fleet and reports it as ours.
sotf_url_origin() {
  if [[ -n "${LCARS_API_URL:-}" || -n "${LCARS_OBS_URL:-}" ]]; then echo "env"
  elif [[ -r "$(sotf_run_dir)/api_url" ]]; then echo "annonce par la fleet (~/.lcars/run/api_url)"
  else echo "derive de l'uid $(sotf_uid)"; fi
}

# ── http_probe <url> — sets SOTF_HTTP_CODE and SOTF_HTTP_BODY ─────────────────────────────────────
# Returns 0 if curl ran (whatever the HTTP code), 1 if curl could not run at all. The caller
# distinguishes "the server answered 500" (a finding) from "I have no curl" (a blind spot) — that
# distinction IS the unreachable/degraded split.
http_probe() {
  local url="$1" timeout="${2:-4}"
  SOTF_HTTP_CODE="" SOTF_HTTP_BODY=""
  have curl || return 1
  local out
  out="$(curl -sS --max-time "$timeout" -w $'\n%{http_code}' "$url" 2>&1)" || {
    # curl itself failed (no route, refused, timeout). `-w` still appended its `000`; strip it so the
    # evidence carries curl's REASON and not a duplicate of the code we are already reporting.
    SOTF_HTTP_CODE="000"
    out="${out%$'\n'000}"
    SOTF_HTTP_BODY="$(trim "${out//$'\n'/ }" 200)"
    return 0
  }
  SOTF_HTTP_CODE="${out##*$'\n'}"
  # FULL body, deliberately untrimmed. Truncation is a PRESENTATION concern and belongs at `emit`;
  # doing it here cut a JSON payload mid-object and made every downstream `jq` fail silently — the
  # readiness endpoint answered correctly and the probe reported "forme inattendue". Callers trim
  # what they quote; they parse what they received.
  SOTF_HTTP_BODY="${out%$'\n'*}"
  return 0
}

# ── sotf_skip_no_fleet <probe> <plane> [complement] — la garde « rien a atteindre » ───────────────
# Returns 0 (and EMITS an `inactive` line) when no fleet was ever started under this human, so the
# caller can `return` immediately. Returns 1 when there IS a fleet and the probe should proceed.
#
# WHY THIS IS SHARED AND NOT INLINE: it is the third time the same rule was needed in a third probe,
# and hand-copying it produced three slightly different verdicts for one situation — `degraded` in
# the fleet plane, `unreachable` in instruments, `degraded` again in pods, on a container where the
# only true statement was "nobody started a fleet here". One rule, one place, or the toolkit
# contradicts itself across its own planes.
#
# The rule itself, learned by measuring two specimens rather than by design:
#   rien de DECLARE a atteindre   → inactive    (absence legitime, ne degrade pas le run)
#   declare mais MUET             → degraded    (mesure prise, resultat mauvais)
#   mon INSTRUMENT est casse      → unreachable (angle mort, aucun constat sur la cible)
sotf_skip_no_fleet() {
  local probe="$1" plane="$2" extra="${3:-}"
  sotf_fleet_ever_started && return 1
  emit "$probe" "$plane" "inactive" "local" "test -d $(sotf_run_dir)" \
    "aucune fleet demarree sous cet humain${extra:+ — $extra}" \
    "Absence de cible declaree, PAS une mesure ratee. Ne prejuge pas d'une fleet lancee par un autre humain : chacun a son bloc de ports et son repertoire de run."
  return 0
}

# ── git_ro <dir> <args…> — the ONLY way this toolkit is allowed to call git ───────────────────────
# Reading a repo with git is NOT automatically free: `status` and friends may refresh the on-disk
# index and may take `index.lock`. That is tolerable on a repo nobody else touches, and it is NOT
# here: `/home/projects/<name>` is driven by `Fleet.Pilot.WorktreeSync`, a GenServer that exists for
# exactly one reason — serialising `git reset --hard` because two of them at once corrupt the index.
# A probe that took that lock, or lost a race against it, would be a diagnostic tool CAUSING the
# incident it reports. `--no-optional-locks` is git's own answer for monitoring processes; we do not
# call git without it, anywhere.
#
# `-c core.fsmonitor=` disables any inherited filesystem monitor (another background writer we do
# not want to wake), and `--git-dir/--work-tree` are deliberately NOT used: we `-C` into the repo so
# a path that is not a repo fails as a probe error instead of silently resolving to an ancestor.
git_ro() {
  local dir="$1"; shift
  git --no-optional-locks -c core.fsmonitor= -C "$dir" "$@"
}

# ── Roots. Imposed container layout (Fleet.Layout, hardcoded there ON PURPOSE — "a config file for
# paths that must never vary would be an API lie"). Overridable here for testing only.
SOTF_PROJECTS_ROOT="${SOTF_PROJECTS_ROOT:-/home/projects}"
SOTF_WORK_ROOT="${SOTF_WORK_ROOT:-/home/projects.work}"

# ── sotf_init — must be called once before any emit ───────────────────────────────────────────────
sotf_init() {
  have jq && SOTF_HAS_JQ=1 || {
    SOTF_HAS_JQ=""
    echo "sotf: jq absent — sortie degradee en TSV, le contrat JSON n'est pas tenu" >&2
  }
}

# ── sotf_exit_code — the house convention, computed from the tallies ──────────────────────────────
# ERROR wins over DRIFT: a run that could not measure is worse than a run that measured a problem,
# because its silence looks like health. UNKNOWN alone does not fail the run — an ambiguity that is
# DECLARED is an honest outcome, not a fault; it is visible in the report and that is its job.
sotf_exit_code() {
  if [[ "$SOTF_ERROR" -gt 0 ]]; then echo 2
  elif [[ "$SOTF_DRIFT" -gt 0 ]]; then echo 1
  else echo 0; fi
}
