defmodule Fleet.CapProfile.MixProject do
  use Mix.Project

  def project do
    [
      app: :fleet_capprofile,
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
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.10"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
