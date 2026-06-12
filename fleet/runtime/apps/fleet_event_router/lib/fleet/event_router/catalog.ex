defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Chargeur du **registry d'events** (`priv/events.yaml`) au boot.

  Fonction pure boot-time (PAS un GenServer — Iron Law : on ne wrappe pas une
  fonction stateless write-once dans un process). Appelée par
  `Fleet.EventRouter.Application.start/2`.

  Rôle (post-fork « subscribers directs = canon », BL-027) : `events.yaml` est un
  **registry pur** — ses clés sont les types d'events autorisés. La consommation
  se fait par **subscribers directs** (`Bus.subscribe` + `handle_info`), PAS par
  une table de dispatch (le GenServer `Dispatch` + `handle_event/1` était inerte,
  retiré). `load!/0` **peuple `authorized_event_types`**
  (`Bus.set_authorized_event_types/1`) → `Bus.broadcast/2` fail-loud sur tout type
  hors registry (verrou anti-récurrence : un event émis non-registré crashe son
  émetteur — les émetteurs dynamiques externes `webhooks_gitea`/`signals_os`/
  `policies`/`Pod.safe_broadcast` rescue `UnregisteredError`, cf. audit BL-027).

  La **pré-registration des atomes** (`String.to_existing_atom` côté émetteurs
  dynamiques) est faite séparément par `Application.preregister_event_atoms/0`
  (inclut les extras `os.signal.*` + variantes `gitea.*` hors registry).

  ## Config

    * `:fleet_event_router, :load_event_registry` — bool, défaut `true`. Mis à
      `false` en `:test` (hermétisme : registry vide → escape-hatch
      `assert_authorized!` `MapSet.size == 0` → broadcast non validé en test).
    * `:fleet_event_router, :events_yaml_path` — override path (défaut
      `priv/events.yaml`).
  """

  require Logger

  @doc """
  Peuple `authorized_event_types` depuis events.yaml si `:load_event_registry`
  est vrai. No-op sinon (test → escape-hatch validation off). Idempotent.
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
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, %{"events" => events}} when is_map(events) ->
        set = events |> Map.keys() |> Enum.map(&String.to_atom/1) |> MapSet.new()
        Fleet.EventRouter.Bus.set_authorized_event_types(set)
        Logger.info("fleet_event_router: registry events.yaml chargé (#{MapSet.size(set)} types)")
        :ok

      _ ->
        Logger.warning("fleet_event_router: events.yaml absent ou invalide à #{path}")
        :ok
    end
  end

  @doc "Résout le path du registry events.yaml (env override ou priv/). Public : réutilisé par `Application.preregister_event_atoms/0` (dedup F035)."
  def events_yaml_path do
    Application.get_env(
      :fleet_event_router,
      :events_yaml_path,
      Path.join(to_string(:code.priv_dir(:fleet_event_router)), "events.yaml")
    )
  end
end
