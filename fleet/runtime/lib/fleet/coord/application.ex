defmodule Fleet.Coord.Application do
  @moduledoc """
  Superviseur de domaine (ex-callback Application de l'app umbrella — collapse Z2
  migration 2026-07-12 ; nom conservé pour zéro churn de références).

  Domain supervisor `fleet_coord`.

  At boot:

    1. `Fleet.Coord.Policies.init_policies!/0` loads YAML +
       persists to `:persistent_term` (fail-fast)
    2. No GenServer started — `Policies` = pure functions,
       no process has a runtime reason to exist

  ## Strategy

  `:one_for_one` but with `[]` children (minimal tree). The supervisor
  exists for supervision-tree consistency.

  ## No pre-registration of event atoms

  The supervisor pre-declares no atom vocab: it would be pointless. The
  events actually emitted (`coord.notification_routed` / `coord.escalation_triggered` /
  `coord.action_dispatched`) are interned at compile-time by the
  `:"coord.*"` literals in `emitter.ex` (the emission pass extracted from Policies) and
  registered in `events.yaml` — no need for a
  `String.to_existing_atom` at boot. (Any atom list placed here would be
  dead vocab, disjoint from what is emitted and never broadcast, like the old
  `@coord_event_atoms` `coord.notify.dashboard`/`coord.action.*` with 0 callers.)

  **Last revised**: 2026-07-18
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    :ok = Fleet.Coord.Policies.init_policies!()

    children = []

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
