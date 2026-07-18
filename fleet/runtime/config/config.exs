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
# (`spec.jury`, schéma-required — accesseur `Fleet.Pilot.Roles.jury/2` ; l'opt
# `:reviewer_roles` reste un seam d'injection test, jamais une config). La voie config
# parallèle est morte avec l'arbitrage « la carte gouverne le jugement ».

if File.exists?(Path.join(__DIR__, "#{Mix.env()}.exs")) do
  import_config "#{Mix.env()}.exs"
end
