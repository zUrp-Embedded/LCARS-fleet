defmodule Fleet.SPBuilder.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_sp_builder,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :eex]
    ]
  end

  defp deps do
    # `jason` retiré (D3) : aucun appel Jason.* dans lib/ ni test/ — dep déclarée sans usage.
    [
      {:fleet_cap_profile, in_umbrella: true},
      # Usage DIRECT (monk.ex `YamlElixir.read_from_file/1`) — déclaré explicitement,
      # plus une résolution transitive silencieuse via fleet_cap_profile.
      {:yaml_elixir, "~> 2.12"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
