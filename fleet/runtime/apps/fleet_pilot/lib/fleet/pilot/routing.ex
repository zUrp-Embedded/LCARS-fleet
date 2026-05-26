defmodule Fleet.Pilot.Routing do
  @moduledoc """
  Pure : catalogue declaratif `forge-routing.yaml` + match d'un event
  Gitea (event_type + payload) → `{:match, pipeline_name}` ou `:no_match`.

  Catalogue : `priv/config/forge-routing.yaml`, override possible via
  `Application.get_env(:fleet_pilot, :forge_routing_path, default)`.
  Format : `routes: [%{"on" => [type1, ...], "when" => %{filters}, "pipeline" => name}]`.

  Filtres `when` reconnus :
    * `type` — valeur après "type:" dans `issue.labels[].name`
    * `state` — valeur après "state:" dans `issue.labels[].name`
    * `assignee` — login d'un des `issue.assignees[].login`

  La 1ère route qui match gagne (ordre = priorité). Toute clé `when`
  absente du filtre = wildcard (ne contraint pas).
  """

  require Logger

  @type route :: %{
          required(String.t()) => any()
        }

  @type match_result :: {:match, pipeline_name :: String.t()} | :no_match

  @doc """
  Charge les routes depuis `forge-routing.yaml` (path résolu via
  `Application.get_env(:fleet_pilot, :forge_routing_path)` avec fallback
  priv_dir). Cache : aucun pour le PoC (lecture à chaque résolution).
  """
  @spec load_routes() :: [route()]
  def load_routes, do: load_routes(routing_path())

  @doc """
  Variante explicite : charge les routes depuis le path donné. Si le
  fichier est absent ou invalide, retourne `[]` (mode désactivé, log
  warning). Utilisée par les tests pour éviter Application.put_env
  (async-safe).
  """
  @spec load_routes(String.t()) :: [route()]
  def load_routes(path) when is_binary(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"routes" => routes}} when is_list(routes) ->
        routes

      {:ok, _other} ->
        Logger.warning(
          "fleet_pilot forge-routing.yaml : clé `routes` absente ou format invalide (#{path}) — auto-dispatch désactivé"
        )

        []

      {:error, reason} ->
        Logger.warning(
          "fleet_pilot forge-routing.yaml : lecture échouée (#{inspect(reason)} ; path=#{path}) — auto-dispatch désactivé"
        )

        []
    end
  end

  @doc """
  Match un event (event_type + payload Gitea) contre les routes chargées.
  Retourne `{:match, pipeline_name}` à la 1ère route qui match, `:no_match`
  sinon.
  """
  @spec match_event(String.t(), map(), [route()]) :: match_result()
  def match_event(event_type, payload, routes)
      when is_binary(event_type) and is_map(payload) and is_list(routes) do
    fields = extract_fields(payload)

    find_matching_route(routes, fn route ->
      matches_event_type?(route, event_type) and matches_when?(route, fields)
    end)
  end

  @doc """
  Match un issue (sans event_type) contre les routes par leur clause
  `when` uniquement. Utilisé par le poller catch-up (`Fleet.Pilot.Poller`)
  qui itère sur les issues ouvertes sans `lcars-dispatched` — pas
  d'event d'origine, donc `on:` est ignoré (le critère est uniquement
  l'état actuel de l'issue).

  Différence sémantique vs `match_event/3` : ici on dispatche sur la
  **forme courante** de l'issue, pas sur un trigger. Cohérent avec le
  modèle "label = source de vérité" : si l'issue match les axes
  (type × state × assignee) et n'a pas le lock → c'est dispatchable.
  """
  @spec match_issue(map(), [route()]) :: match_result()
  def match_issue(payload, routes) when is_map(payload) and is_list(routes) do
    fields = extract_fields(payload)
    find_matching_route(routes, &matches_when?(&1, fields))
  end

  @doc """
  Extrait les champs `type`, `state`, `assignee` d'un payload Gitea
  (webhook issue). Pure. Retourne `nil` pour les champs absents.
  """
  @spec extract_fields(map()) :: %{
          type: String.t() | nil,
          state: String.t() | nil,
          assignee: String.t() | nil
        }
  def extract_fields(payload) do
    issue = Map.get(payload, "issue", %{})
    labels = Map.get(issue, "labels", [])

    %{
      type: extract_label_value(labels, "type:"),
      state: extract_label_value(labels, "state:"),
      assignee: extract_first_assignee(issue)
    }
  end

  # ============================================================
  # Internals
  # ============================================================

  defp find_matching_route(routes, predicate) when is_function(predicate, 1) do
    Enum.find_value(routes, :no_match, fn route ->
      if predicate.(route) do
        case Map.get(route, "pipeline") do
          name when is_binary(name) and name != "" -> {:match, name}
          _ -> nil
        end
      end
    end)
  end

  defp routing_path do
    Application.get_env(:fleet_pilot, :forge_routing_path) || default_routing_path()
  end

  defp default_routing_path do
    :fleet_pilot
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("config/forge-routing.yaml")
  end

  defp matches_event_type?(%{"on" => on}, event_type) when is_list(on) do
    event_type in on
  end

  defp matches_event_type?(%{"on" => on}, event_type) when is_binary(on) do
    on == event_type
  end

  defp matches_event_type?(_route, _event_type), do: false

  defp matches_when?(route, fields) do
    when_clause = Map.get(route, "when", %{})

    Enum.all?(when_clause, fn {key, expected} ->
      match_field?(fields, key, expected)
    end)
  end

  defp match_field?(fields, "type", expected), do: fields.type == expected
  defp match_field?(fields, "state", expected), do: fields.state == expected
  defp match_field?(fields, "assignee", expected), do: fields.assignee == expected
  defp match_field?(_fields, _unknown_key, _expected), do: false

  defp extract_label_value(labels, prefix) when is_list(labels) do
    Enum.find_value(labels, fn
      %{"name" => name} when is_binary(name) ->
        if String.starts_with?(name, prefix),
          do: String.replace_prefix(name, prefix, ""),
          else: nil

      _ ->
        nil
    end)
  end

  defp extract_label_value(_labels, _prefix), do: nil

  defp extract_first_assignee(%{"assignees" => [%{"login" => login} | _]})
       when is_binary(login),
       do: login

  defp extract_first_assignee(_issue), do: nil
end
