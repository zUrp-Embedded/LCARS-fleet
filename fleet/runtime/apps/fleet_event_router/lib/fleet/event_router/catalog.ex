defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Boot-time loader of the **event registry** (`priv/events.yaml`).

  Pure boot-time function (NOT a GenServer — Iron Law: we do not wrap a
  stateless write-once function in a process). Called by
  `Fleet.EventRouter.Application.start/2`.

  Role: `events.yaml` is a **pure registry** — its keys are the authorized event
  types. Consumption happens through **direct subscribers** (`Bus.subscribe` +
  `handle_info`); there is NO dispatch table. `load!/0` **populates
  `authorized_event_types`** (`Bus.set_authorized_event_types/1`) → `Bus.broadcast/2`
  fails loud on any type outside the registry: an emitted, unregistered event crashes
  its emitter. The external dynamic emitters (`webhooks_gitea`/`signals_os`/
  `policies`/`Pod.best_effort_broadcast`) rescue `UnregisteredError` so as not to die
  on an unexpected type; the `pod.completed` lifecycle, on the other hand, goes through
  `Pod.required_broadcast` which PROPAGATES the failure instead of swallowing it (a
  load-bearing event swallowed would mask the end of step_run and leave the lock held).

  The **atom pre-registration** (`String.to_existing_atom` on the dynamic-emitter
  side) is done separately by `Application.preregister_event_atoms/0`
  (includes the `os.signal.*` extras + `gitea.*` variants outside the registry).

  ## Config

    * `:fleet_event_router, :load_event_registry` — bool, default `true`. Set to
      `false` in `:test` (hermeticity: empty registry → escape-hatch
      `assert_authorized!` `MapSet.size == 0` → broadcast not validated in test).
    * `:fleet_event_router, :events_yaml_path` — path override (default
      `priv/events.yaml`).
  """

  require Logger

  @doc """
  Populates `authorized_event_types` from events.yaml if `:load_event_registry`
  is true. No-op otherwise (test → escape-hatch, validation off). Idempotent.
  """
  @spec load!() :: :ok
  def load! do
    if Application.get_env(:fleet_event_router, :load_event_registry, true) do
      do_load()
    else
      :ok
    end
  end

  defp do_load do
    case parse_events() do
      {:ok, events} when map_size(events) > 0 ->
        set = events |> Map.keys() |> Enum.map(&String.to_atom/1) |> MapSet.new()
        Fleet.EventRouter.Bus.set_authorized_event_types(set)
        Logger.info("Catalog: registry events.yaml chargé (#{MapSet.size(set)} types)")
        :ok

      {:ok, events} when map_size(events) == 0 ->
        # events.yaml VALID but EMPTY (`events: {}`) in a real regime: setting this empty MapSet via
        # set_authorized_event_types would leave the Bus (permissive on an empty registry by default)
        # broadcasting EVERY type WITHOUT validation — exactly the same silent fail-open as the
        # absent/invalid case below, a "green" deploy but a dead registry. `do_load` is reached only
        # in a real boot (`load_event_registry: true`; test sets `false`) → an empty registry here =
        # a broken deploy. Fail-loud at boot, like an absent/invalid events.yaml.
        raise "fleet_event_router: events.yaml VIDE (events: {}) à #{events_yaml_path()} — un " <>
                "registry vide laisserait le Bus broadcaster TOUT type sans validation (deploy cassé). " <>
                "Fail-loud au boot, comme un events.yaml absent/invalide."

      :error ->
        # Deliberate crash-boot ("broken deploy ⇒ we do not boot"): an absent/invalid events.yaml
        # that would WARN then return `:ok` would leave `authorized_event_types` empty →
        # `assert_authorized!` escape-hatch (empty MapSet) → the Bus would broadcast EVERY type
        # WITHOUT validation, a "green" deploy but a dead registry. `do_load` is reached only in
        # prod/dev (`load_event_registry: true`; test sets `false`) → here we are necessarily in a
        # real boot that wants the registry. Fail-loud: raise in `Application.start` → the BEAM does
        # not come up, the launcher redeploys. We do NOT start a Bus without validation.
        raise "fleet_event_router: events.yaml absent ou invalide à #{events_yaml_path()} — " <>
                "registry d'events non chargeable (deploy cassé). Fail-loud au boot : un Bus sans " <>
                "registry validerait n'importe quel type. Réparer/redéployer priv/events.yaml."
    end
  end

  @doc """
  Type-keys of the events.yaml registry (strings). **Single parse source** — reused
  by `do_load/0` AND `Application.preregister_event_atoms/0`: the file is located/
  parsed in a SINGLE place at boot, so no risk of shape drift between the two. Returns `[]`
  if events.yaml is absent/invalid.
  """
  @spec event_type_strings() :: [String.t()]
  def event_type_strings do
    case parse_events() do
      {:ok, events} -> Map.keys(events)
      :error -> []
    end
  end

  # The events.yaml parse in ONE single place: locates + reads + validates the shape.
  # `{:ok, events_map}` if present and `events:` is a map (EMPTY map included — `parse_events` does
  # NOT decide the verdict on emptiness, it just returns `{:ok, %{}}`); `:error` if absent/invalid.
  # It is the TWO callers that decide on emptiness:
  #   * do_load → FAIL-LOUD (raise) on an empty map in a real regime — an empty registry would open
  #     the Bus to EVERY type without validation — AND on `:error` (same reason).
  #   * event_type_strings → `[]` on an empty map (preregister has nothing to pre-register) as on :error.
  defp parse_events do
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, %{"events" => events}} when is_map(events) -> {:ok, events}
      _ -> :error
    end
  end

  @doc "Resolves the path of the events.yaml registry (env override or priv/). Public: reused by `Application.preregister_event_atoms/0` (single parse source)."
  def events_yaml_path do
    Application.get_env(
      :fleet_event_router,
      :events_yaml_path,
      Path.join(to_string(:code.priv_dir(:fleet_event_router)), "events.yaml")
    )
  end
end
