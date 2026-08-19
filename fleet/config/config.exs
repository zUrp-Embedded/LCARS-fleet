# Config compile-time de l'app OTP unique :lcars_fleet (ex-umbrella collapsée, migration Z3 2026-07-12).
# Les <env>.exs sont importés en bas de fichier.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

# Le jury (juges PR) n'a PLUS de config moteur : LA CARTE workflow est la source unique
# (`spec.jury`, schéma-required — accesseur `Fleet.Project.Roles.jury/2` ; l'opt
# `:reviewer_roles` reste un seam d'injection test, jamais une config). La voie config
# parallèle est morte avec l'arbitrage « la carte gouverne le jugement ».

if File.exists?(Path.join(__DIR__, "#{Mix.env()}.exs")) do
  import_config "#{Mix.env()}.exs"
end

# GitWand kill-switch (tier 0 ONLY: deterministic conflict diagnosis + trivial auto-resolution —
# the jury still re-judges the pushed head). OFF by default and stated HERE rather than left to a
# `get_env` default: a capability whose only trace is the absence of a line is one an operator
# cannot discover, and cannot audit as deliberately off. This is an ADMIN setting: the box-wide
# file `/etc/lcars/fleet.json` (`{"conflict_engine": true}`, root-owned, read once at boot by
# `runtime.exs`) is how it turns on — inherited from the engine's origin project: off at install,
# the admin opts in. Seams: `:conflict_diagnoser`, `:conflict_applier`.
# (A1 — this flag used to ALSO gate the tier-2 chief pass: one switch, two owners. The chief pass
# is FLEET design and lives on its own flag below; the admin's GitWand choice no longer silently
# removes a rung of the fleet's escalation ladder.)
config :lcars_fleet, pilot_conflict_diagnosis?: false

# Chief exception pass (tier 2: ONE outsider inference pass on a conflict the producer could not
# close, before immobilizing a human). FLEET design flag, not an admin knob. Was OFF until a real
# conflict converged end-to-end on a bench — CONDITION MET 2026-08-18 (probe-rails PR#28,
# image 3441e1de2): budget exhausted → chief pod → fresh base (A0.5) → resolution delivered ON the
# PR (A0.6), trailer LCARS-chief → CI retick → merged_by system_chief. Three real defects were
# found and fixed by that proof before this line could flip.
config :lcars_fleet, pilot_conflict_exception_pass?: true

# Gatekeeper arbitration pass (verdict rail, tier 2: ONE outsider ruling on a GRAY ZONE — the jury
# approved and the card's curve refuses on the judges' own findings — before immobilizing a human).
# FLEET design flag, twin of the conflict pass above. Was OFF for the same reason its twin was — a
# rung that has never fired end-to-end is a hypothesis — and its flip condition was written here,
# identical: one gray zone arbitrated from summon to seal on a real project.
#
# CONDITION MET 2026-08-19 (probe-rails PR71, and again PR72), and it was not staged: the gray zone
# occurred on its own the moment the judges could emit their measurements. Card `standard-qa`, two
# FAVOURABLE OPINIONS, one `minor` finding under a `minor` floor → 12:09:13 summon posted
# ([verdict-gatekeeper:pr-71:round-1]) → 12:11:09 the gatekeeper ruled → merged_by
# system_gatekeeper. The log carries the other half of the contract too: "non-jury reviewer
# ['gatekeeper'] — IGNORED from the jury" (F-C061) — the arbiter's voice is read by `arbitrated/2`
# in the gray zone and NOWHERE else.
#
# ⚠ THE PROOF RAN WITH THIS LINE ALREADY `true` ON THE BENCH while the tree said `false` (measured
# by RPC on the node, 2026-08-19) — so until this commit, the proven configuration was not the
# shipped one, and a taker of this branch got a rung that escalates to the arch instead of
# summoning. That gap is the reason this flip is its own commit rather than a line inside another.
config :lcars_fleet, pilot_verdict_exception_pass?: true
