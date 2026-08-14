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

# Conflict engine (tier 0 deterministic diagnosis + tier 2 gatekeeper pass). OFF by default and
# stated HERE rather than left to a `get_env` default: a capability whose only trace is the absence
# of a line is one an operator cannot discover, and cannot audit as deliberately off.
# ON → `Remediation` routes trivial conflicts to auto-resolution (the jury still re-judges the
# pushed head) and gives the gatekeeper one pass before the human. OFF → producer then arch,
# unchanged. Seams: `:conflict_diagnoser`, `:conflict_applier`.
config :lcars_fleet, pilot_conflict_diagnosis?: false
