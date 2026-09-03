# Config compile-time de l'app OTP unique :lcars_fleet.
# Les <env>.exs sont importés en bas de fichier.
import Config

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

# Le jury (juges PR) n'a PAS de config moteur : LA CARTE workflow est la source unique
# (`spec.jury`, schéma-required — accesseur `Fleet.Project.Roles.jury/2` ; l'opt
# `:reviewer_roles` reste un seam d'injection test, jamais une config). ⚖ La carte gouverne le
# jugement : une voie config parallèle serait une seconde autorité.

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
# (A1 — this flag does NOT gate the tier-2 chief pass: that would be one switch with two owners.
# The chief pass is FLEET design and lives on its own flag below, so the admin's GitWand choice
# cannot silently remove a rung of the fleet's escalation ladder.)
config :lcars_fleet, pilot_conflict_diagnosis?: false

# Chief exception pass (tier 2: ONE outsider inference pass on a conflict the producer could not
# close, before immobilizing a human). FLEET design flag, not an admin knob.
#
# ⚖ UN BARREAU QUI N'A JAMAIS TIRE DE BOUT EN BOUT EST UNE HYPOTHESE : un tel drapeau part OFF et
# ne bascule que sur une convergence reelle. Celle-ci : budget epuise → chief pod → base fraiche
# (A0.5) → resolution livree SUR la PR (A0.6), trailer LCARS-chief → CI retick → merged_by
# system_chief. Trois defauts reels ont ete trouves et corriges par cette preuve avant la bascule.
config :lcars_fleet, pilot_conflict_exception_pass?: true

# Gatekeeper arbitration pass (verdict rail, tier 2: ONE outsider ruling on a GRAY ZONE — the jury
# approved and the card's curve refuses on the judges' own findings — before immobilizing a human).
# FLEET design flag, twin of the conflict pass above, and it answers the SAME flip condition: one
# gray zone arbitrated from summon to seal on a real project.
#
# That convergence was not staged: the gray zone occurred on its own the moment the judges could
# emit their measurements. Card `standard-qa`, two
# FAVOURABLE OPINIONS, one `minor` finding under a `minor` floor → 12:09:13 summon posted
# ([verdict-gatekeeper:pr-71:round-1]) → 12:11:09 the gatekeeper ruled → merged_by
# system_gatekeeper. The log carries the other half of the contract too: "non-jury reviewer
# ['gatekeeper'] — IGNORED from the jury" (F-C061) — the arbiter's voice is read by `arbitrated/2`
# in the gray zone and NOWHERE else.
#
# ⚠ LA CONFIGURATION PROUVEE DOIT ETRE CELLE QUI EST LIVREE. Une preuve jouee sur un banc dont
# cette ligne vaut `true` pendant que l'arbre dit `false` ne prouve rien sur ce qu'un preneur de
# cette branche obtient : il obtient un barreau qui escalade vers l'arch au lieu de convoquer. Le
# banc se mesure par RPC sur le noeud, pas par lecture du fichier.
config :lcars_fleet, pilot_verdict_exception_pass?: true
