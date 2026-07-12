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

# Jury (juges PR) du modèle single-brique : les rôles dont la review est demandée sur la PR d'un
# producteur, et qui sont seedés comme collaborateurs write à l'onboarding (sinon leur verdict ne
# compterait pas au gate forge). Source data UNIQUE du jury (compile-time default, déclarée ici une
# seule fois — l'accesseur est `Fleet.Pilot.Roles.reviewer_roles/1`). Surchargeable par projet/test
# via l'opt `:reviewer_roles`.
config :fleet_pilot, reviewer_roles: ["qualifier", "reviewer"]

if File.exists?(Path.join(__DIR__, "#{Mix.env()}.exs")) do
  import_config "#{Mix.env()}.exs"
end
