import Config

# Jury roles come from the workflow card (Fleet.Project.Roles.jury/2), not engine config.
# reviewer_roles is a test injection seam.

if File.exists?(Path.join(__DIR__, "#{Mix.env()}.exs")) do
  import_config "#{Mix.env()}.exs"
end

# Tier-0 deterministic conflict diagnosis/resolution is admin opt-in via /etc/lcars/fleet.json
# at boot. The jury still evaluates the pushed head. This switch does not control the chief pass.
config :lcars_fleet, pilot_conflict_diagnosis?: false

# Tier-2 chief conflict pass: one outsider attempt after producer rework. Fleet design flag.
config :lcars_fleet, pilot_conflict_exception_pass?: true

# Tier-2 verdict arbitration for an approved jury verdict rejected by the card's findings curve.
# The gatekeeper's ruling is separate from jury votes. Fleet design flag.
config :lcars_fleet, pilot_verdict_exception_pass?: true
