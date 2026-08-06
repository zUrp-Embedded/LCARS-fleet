defmodule Fleet.Coord.Application do
  @moduledoc """
  Coord domain supervisor ("Application" is a historical name, kept to avoid
  reference churn — this is a plain Supervisor, not an OTP app callback).

  At boot:

    1. `Fleet.Coord.Policies.init_policies!/0` loads YAML +
       persists to `:persistent_term` (fail-fast)
    2. No GenServer started — `Policies` = pure functions,
       no process has a runtime reason to exist

  ## Strategy

  `:one_for_one` but with `[]` children (minimal tree). The supervisor
  exists for supervision-tree consistency.

  ## No pre-registration of event atoms

  The supervisor pre-declares no atom vocab: the events actually emitted
  (`coord.notification_routed` / `coord.escalation_triggered` /
  `coord.action_dispatched`) are interned at compile-time by the
  `:"coord.*"` literals in `emitter.ex` and registered in `events.yaml` — no
  `String.to_existing_atom` needed at boot. An atom list placed here would be
  a SECOND copy of the vocabulary, free to drift from what is emitted.
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
