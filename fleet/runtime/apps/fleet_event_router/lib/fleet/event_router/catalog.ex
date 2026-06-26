defmodule Fleet.EventRouter.Catalog do
  @moduledoc """
  Chargeur du **registry d'events** (`priv/events.yaml`) au boot.

  Fonction pure boot-time (PAS un GenServer — Iron Law : on ne wrappe pas une
  fonction stateless write-once dans un process). Appelée par
  `Fleet.EventRouter.Application.start/2`.

  Rôle : `events.yaml` est un **registry pur** — ses clés sont les types d'events
  autorisés. La consommation se fait par **subscribers directs** (`Bus.subscribe` +
  `handle_info`), il n'y a PAS de table de dispatch. `load!/0` **peuple
  `authorized_event_types`** (`Bus.set_authorized_event_types/1`) → `Bus.broadcast/2`
  fait fail-loud sur tout type hors registry : un event émis non-registré crashe son
  émetteur. Les émetteurs dynamiques externes (`webhooks_gitea`/`signals_os`/
  `policies`/`Pod.best_effort_broadcast`) rescue `UnregisteredError` pour ne pas mourir
  sur un type inattendu ; en revanche le lifecycle `pod.completed` passe par
  `Pod.required_broadcast` qui PROPAGE l'échec au lieu de l'avaler (un event
  load-bearing avalé masquerait la fin de hop et laisserait le verrou tenu).

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
    case parse_events() do
      {:ok, events} when map_size(events) > 0 ->
        set = events |> Map.keys() |> Enum.map(&String.to_atom/1) |> MapSet.new()
        Fleet.EventRouter.Bus.set_authorized_event_types(set)
        Logger.info("fleet_event_router: registry events.yaml chargé (#{MapSet.size(set)} types)")
        :ok

      {:ok, events} when map_size(events) == 0 ->
        # events.yaml VALIDE mais VIDE (`events: {}`) en régime réel : poser ce MapSet vide via
        # set_authorized_event_types laisserait le Bus (permissif sur registry vide par défaut)
        # broadcaster TOUT type SANS validation — exactement le même fail-open silencieux que le cas
        # absent/invalide ci-dessous, deploy « vert » mais registry mort. `do_load` n'est atteint
        # qu'en boot réel (`load_event_registry: true` ; test pose `false`) → un registry vide ici =
        # deploy cassé. Fail-loud au boot, comme un events.yaml absent/invalide.
        raise "fleet_event_router: events.yaml VIDE (events: {}) à #{events_yaml_path()} — un " <>
                "registry vide laisserait le Bus broadcaster TOUT type sans validation (deploy cassé). " <>
                "Fail-loud au boot, comme un events.yaml absent/invalide."

      :error ->
        # Crash-boot volontaire (« deploy cassé ⇒ on ne boot pas ») : un events.yaml absent/invalide
        # qui WARNerait puis rendrait `:ok` laisserait `authorized_event_types` vide →
        # `assert_authorized!` escape-hatch (MapSet vide) → le Bus broadcasterait TOUT type SANS
        # validation, deploy « vert » mais registry mort. `do_load` n'est atteint qu'en prod/dev
        # (`load_event_registry: true` ; test pose `false`) → ici on est forcément dans un boot réel
        # voulant le registry. Fail-loud : raise dans `Application.start` → le BEAM ne monte pas, le
        # launcher redéploie. On NE démarre PAS un Bus sans validation.
        raise "fleet_event_router: events.yaml absent ou invalide à #{events_yaml_path()} — " <>
                "registry d'events non chargeable (deploy cassé). Fail-loud au boot : un Bus sans " <>
                "registry validerait n'importe quel type. Réparer/redéployer priv/events.yaml."
    end
  end

  @doc """
  Clés-types du registry events.yaml (strings). **Source unique du parse** — réutilisée
  par `do_load/0` ET `Application.preregister_event_atoms/0` : le fichier n'est localisé/
  parsé qu'une fois au boot, donc pas de risque de drift de shape entre les deux. Rend `[]`
  si events.yaml est absent/invalide.
  """
  @spec event_type_strings() :: [String.t()]
  def event_type_strings do
    case parse_events() do
      {:ok, events} -> Map.keys(events)
      :error -> []
    end
  end

  # Le parse events.yaml en UN seul endroit : localise + lit + valide la shape.
  # `{:ok, events_map}` si présent et `events:` est une map (map VIDE incluse — `parse_events` ne
  # tranche pas le verdict sur le vide, il rend juste `{:ok, %{}}`) ; `:error` si absent/invalide.
  # Ce sont les DEUX callers qui tranchent le vide :
  #   * do_load → FAIL-LOUD (raise) sur map vide en régime réel — un registry vide ouvrirait le Bus
  #     à TOUT type sans validation — ET sur `:error` (même raison).
  #   * event_type_strings → `[]` sur map vide (preregister n'a rien à pré-enregistrer) comme sur :error.
  defp parse_events do
    path = events_yaml_path()

    case File.exists?(path) && YamlElixir.read_from_file(path) do
      {:ok, %{"events" => events}} when is_map(events) -> {:ok, events}
      _ -> :error
    end
  end

  @doc "Résout le path du registry events.yaml (env override ou priv/). Public : réutilisé par `Application.preregister_event_atoms/0` (source de parse unique)."
  def events_yaml_path do
    Application.get_env(
      :fleet_event_router,
      :events_yaml_path,
      Path.join(to_string(:code.priv_dir(:fleet_event_router)), "events.yaml")
    )
  end
end
