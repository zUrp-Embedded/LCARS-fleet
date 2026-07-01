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
      # `:fleet_event_router` : ex-DÉPENDANCE OTP forcée pour ordering au boot
      # release — justifiée par `Fleet.MCP.Bridge.init/1` qui appelait
      # `Phoenix.PubSub.subscribe(Fleet.PubSub, …)` (registry hébergé par
      # fleet_event_router ; #576 "unknown registry: Fleet.PubSub" au boot live).
      # Z7.3 (2026-06-10) : Bridge RETIRÉ → plus AUCUN usage de Fleet.PubSub dans
      # fleet_mcp/lib → cette dépendance est désormais VESTIGIALE. Conservée ce
      # passage (sibling umbrella toujours présent, retrait = changement d'ordre de
      # boot → risque #576) ; candidate au retrait avec preuve (SIGNAL auditeur).
      # Pas de cycle (fleet_event_router ne dépend pas de fleet_mcp).
      extra_applications: [:logger, :fleet_event_router],
      mod: {Fleet.MCP.Application, []}
    ]
  end

  defp deps do
    # ex_mcp : SDK MCP/ACP Elixir, multi-transport (stdio/HTTP-SSE/BEAM) — wrap opaque
    #          via Fleet.MCP.PodTools (`use ExMCP.Server`, bascule Hermes possible).
    # phoenix_pubsub : bus interne (fan-out broadcast — PAS via GenServer, anti-goulot OTP).
    # jason : encode/decode JSON des payloads d'outils MCP (get_work_item/submit_result).
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
      {:jason, "~> 1.4"},
      # fleet_event_router : Bus + Fleet.Event + Fleet.PubSub (Ring 0). Déjà en
      #   extra_applications (ordering OTP boot) ; ici en dep compile-time. Ring 4→0, pas de cycle.
      {:fleet_event_router, in_umbrella: true},
      # fleet_task_queue : le broker d'orchestration que PodTools sert via get_work_item/submit_result
      #   (drive métier ADR-G ; le broker broadcast lui-même %Fleet.Event{work_item.completed}).
      #   Ring 4→Ring 2 (fleet_mcp sert la queue, n'orchestre pas — DN drive/mcp-server §E). Pas de cycle.
      {:fleet_task_queue, in_umbrella: true},
      # fleet_credentials : Fleet.Credentials.RoleToken — token forge du compte de rôle, pour que
      #   l'arch poste l'issue EN SON NOM (create_issue). Ring 4→Ring 1, descendant, pas de cycle.
      {:fleet_credentials, in_umbrella: true}
      # Z5 (MCP-D1) — `yaml_elixir` retiré : ne servait qu'à parser mcp-channels.yaml /
      #   mcp-bridge.yaml pour `Fleet.MCP.Schema`, tous retirés (substrat channels mort).
      #   Plus aucun usage YamlElixir dans fleet_mcp (lib + test).
    ]
  end
end
