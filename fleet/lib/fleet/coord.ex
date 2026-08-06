defmodule Fleet.Coord do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.Decision,
      Fleet.SchemaCache,
      Fleet.EventRouter
    ],
    exports: []

  @moduledoc """
  Declarative coordination backend.

  `Policies` maps validated decisions and Cat-5 escalations to actions and
  escalation paths; `Emitter` broadcasts the resulting canonical events.
  This domain performs no inference and starts no worker process.
  """

  defdelegate handle_decision(decision, correlation_id), to: Fleet.Coord.Policies
  defdelegate handle_escalation(source, payload, correlation_id), to: Fleet.Coord.Policies

  @doc """
  Loads and validates the escalation policy table used at boot.
  """
  defdelegate init_policies!(), to: Fleet.Coord.Policies
end
