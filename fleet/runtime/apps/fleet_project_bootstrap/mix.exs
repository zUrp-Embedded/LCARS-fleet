defmodule Fleet.ProjectBootstrap.MixProject do
  use Mix.Project

  # Lot 2 (plan-implementation.md) — core du pod : prépare pod_dir vanilla
  # AVANT spawn (branch feature + /init mimic + bind creds + mount-binds).
  # DN : ring1/fleet_project_bootstrap.md. Vendor-agnostic (stdlib + :eex),
  # AUCUNE dep externe (indépendant du blocant jose #551 — Lot 1).
  # Invoqué par Fleet.Spawner.Pod phase PROJECT (chantier 6 PROMOTED).

  def project do
    [
      app: :fleet_project_bootstrap,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :eex],
      mod: {Fleet.ProjectBootstrap.Application, []}
    ]
  end

  defp deps do
    # fleet_cap_profile : struct %Fleet.CapProfile{} consommée (spec.project.*).
    # fleet_credentials : Phase.Clone délègue l'auth git système à Fleet.Credentials.ForgeAuth.git_env/0 (source unique F095).
    # Pas de dep Hex externe → pas de blocant compile (cf. jose #551 Lot 1).
    [
      {:fleet_cap_profile, in_umbrella: true},
      {:fleet_credentials, in_umbrella: true}
    ]
  end
end
