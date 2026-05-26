defmodule Fleet.MCP.MixProject do
  use Mix.Project

  # Lot 1 (plan-implementation.md) — MCP substrat Ring 4.
  # DN sources : ring4/fleet_mcp.md + ring4/mcp-channels-substrate.md + adr-c-5-zeros.md.
  # SDK MCP Elixir = ExMCP (azmaveth) — version réelle Hex 0.9.1 (la DN supposait
  # ~>0.5.0, corrigé par cross-check Hex #M6/feedback_doctrine_below_substrate).
  # Pin exact figé post-PoC channels-push (discipline SDK #1).

  def project do
    [
      app: :fleet_mcp,
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
      # `:fleet_event_router` : DÉPENDANCE OTP forcée pour ordering au
      # boot release. `Fleet.MCP.Bridge.init/1` appelle
      # `Phoenix.PubSub.subscribe(Fleet.PubSub, …)` (bridge.ex:60, registry
      # Fleet.PubSub hébergé par fleet_event_router). Sans cette
      # dépendance, l'ordre `release.applications` ne suffit pas (4e
      # défaut deploy-time capté par Starfleet #576 : ArgumentError
      # "unknown registry: Fleet.PubSub" au boot systemd live ; cascade
      # `ensure_all_started` masquait — l'ordre release strict expose).
      # Pas de cycle (fleet_event_router ne dépend pas de fleet_mcp).
      extra_applications: [:logger, :fleet_event_router],
      mod: {Fleet.MCP.Application, []}
    ]
  end

  defp deps do
    # ex_mcp : SDK MCP/ACP Elixir, multi-transport (stdio/HTTP-SSE/BEAM) — wrap opaque
    #          via Fleet.MCP.Server (discipline SDK #2, bascule Hermes possible).
    # phoenix_pubsub : bus interne (fan-out broadcast — PAS via GenServer, anti-goulot OTP).
    # ex_json_schema + jason : validation events au broadcast (cohérent Lot 0bis).
    # jose : pin override 1.11.10 — ex_mcp tire jose transitivement à 1.11.12 qui
    #        exige OTP27 (`dynamic()` undefined), or env = OTP25. 1.11.10 =
    #        dernière révision OTP25-compatible. Sanctionné starfleet #551
    #        (escalade A-Y-7 anti-acharnement : root-cause diagnostiqué 1 passe,
    #        pas de brute-force plomberie). override: true force la résolution
    #        au-dessus du pin transitif d'ex_mcp.
    [
      {:ex_mcp, "~> 0.9.1"},
      {:jose, "1.11.10", override: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:ex_json_schema, "~> 0.11"},
      {:jason, "~> 1.4"},
      # fleet_event_router : Bus (Ring 0) — PodTools broadcaste `pod.result_submitted` sur
      #   submit_result (brick 2.1). Déjà en extra_applications (ordering OTP) ; ici en dep
      #   compile-time pour la visibilité du module Bus (sinon warning undefined, casse
      #   --warnings-as-errors CI). Ring 4→Ring 0 OK, pas de cycle.
      {:fleet_event_router, in_umbrella: true},
      # yaml_elixir : parse configs canon (mcp-channels.yaml / mcp-bridge.yaml)
      #   pour validation Fleet.MCP.Schema (version 2.12 = alignée
      #   fleet_event_router/fleet_coord/fleet_pipeline, déjà dans mix.lock).
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
