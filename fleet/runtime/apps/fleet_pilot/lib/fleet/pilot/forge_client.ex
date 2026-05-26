defmodule Fleet.Pilot.ForgeClient do
  @moduledoc """
  Client minimal Gitea REST API pour `fleet_pilot`. Une seule
  opération : `add_label/4` (PUT label set idempotent) — utilisée par
  `Fleet.Pilot.AutoDispatcher` pour poser le lock `lcars-dispatched`
  avant invoke pipeline.

  ## Configuration

  Résolue à l'appel via `opts` (Keyword) ou fallback
  `Application.get_env(:fleet_pilot, :forge)` :

    * `:base_url` — ex `"http://localhost:3000"` (laptop mirror) ou
      `"http://10.42.0.118"` (forge NAS).
    * `:token` — token Gitea. Lu depuis `:token_file` si absent.
    * `:token_file` — path fichier (défaut `~/.gitea_token`, convention
      v1.5).
    * `:req_options` — options passées tel quel à `Req.new/1` (pour
      tests : `[plug: ...]` pour intercepter HTTP).

  ## Idempotence

  Pattern `GET issue labels + PUT label set` (cf. v1.5
  `gitea/gitea-client.py:135-138` : ticket 153-D — POST append cause
  doublons). Re-call sur label déjà présent = `{:ok, :already_present}`,
  zéro round-trip d'écriture.

  ## Pas de cache

  Chaque `add_label/4` re-fetche `/labels?limit=100` (mapping name→id).
  ~2KB, LAN-rapide. Optimisation cache (`:persistent_term`) à voir si
  contention mesurée.
  """

  require Logger

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  @doc """
  Ajoute le label `label_name` à l'issue `repo`/`issue_number` côté
  forge. Idempotent : si le label est déjà présent, aucune écriture.

  ## Returns

    * `{:ok, :added}` — label fraîchement ajouté
    * `{:ok, :already_present}` — label déjà sur l'issue (no-op)
    * `{:error, {:label_unknown, label_name}}` — label n'existe pas
      dans le repo (à pre-provisioner côté forge)
    * `{:error, {:http, status, body}}` — réponse HTTP non-2xx
    * `{:error, {:transport, reason}}` — échec réseau / DNS / ...
    * `{:error, {:config, reason}}` — config manquante / token illisible
  """
  @spec add_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :added | :already_present}
          | {:error, term()}
  def add_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number),
         current_names = Enum.map(current, & &1["name"]),
         false <- label_name in current_names && :already_present,
         {:ok, labels_index} <- get_labels_index(config, repo),
         {:ok, label_id} <- lookup_label(labels_index, label_name),
         current_ids = Enum.map(current, & &1["id"]),
         new_ids = Enum.uniq([label_id | current_ids]),
         :ok <- put_issue_labels(config, repo, issue_number, new_ids) do
      {:ok, :added}
    else
      :already_present -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  @doc """
  Liste les issues ouvertes du `repo` qui n'ont PAS le label `exclude_label`
  (filtrage client-side : Gitea n'expose pas la négation côté query).
  Utilisé par `Fleet.Pilot.Poller` (catch-up tickets sans
  `lcars-dispatched`).

  ## Returns

    * `{:ok, [issue]}` — issues filtrées, payloads bruts Gitea
    * `{:error, term()}` — propagation des erreurs HTTP/transport/config

  ## Pagination

  Limite hard-coded à 50 issues/page, 1 seule page. Pour les opérations
  catch-up, ça couvre largement la fenêtre de catch-up post-crash. Si
  le poller doit traiter +50 issues entre 2 ticks, c'est un signe que
  l'interval est trop long ou la forge en burst — sujet de tuning, pas
  de PR (cf. v1.5 `LcarsFleetPoller` même limite).
  """
  @spec list_open_issues_without_label(String.t(), String.t(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list_open_issues_without_label(repo, exclude_label, opts \\ [])
      when is_binary(repo) and is_binary(exclude_label) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, issues} <-
           http_get(config, "/repos/#{repo}/issues?state=open&type=issues&limit=50") do
      filtered =
        Enum.reject(issues, fn issue ->
          labels = Map.get(issue, "labels", [])
          Enum.any?(labels, fn l -> Map.get(l, "name") == exclude_label end)
        end)

      {:ok, filtered}
    end
  end

  # ============================================================
  # HTTP plumbing
  # ============================================================

  defp get_issue_labels(config, repo, issue_number) do
    case http_get(config, "/repos/#{repo}/issues/#{issue_number}/labels") do
      {:ok, labels} when is_list(labels) -> {:ok, labels}
      {:error, _} = err -> err
    end
  end

  defp get_labels_index(config, repo) do
    case http_get(config, "/repos/#{repo}/labels?limit=100") do
      {:ok, labels} when is_list(labels) ->
        index = Map.new(labels, fn %{"name" => n, "id" => id} -> {n, id} end)
        {:ok, index}

      {:error, _} = err ->
        err
    end
  end

  defp put_issue_labels(config, repo, issue_number, label_ids) do
    case http_put(
           config,
           "/repos/#{repo}/issues/#{issue_number}/labels",
           %{labels: label_ids}
         ) do
      {:ok, _body} -> :ok
      {:error, _} = err -> err
    end
  end

  defp lookup_label(index, name) do
    case Map.fetch(index, name) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:label_unknown, name}}
    end
  end

  defp http_get(config, path), do: request(config, :get, path, nil)
  defp http_put(config, path, body), do: request(config, :put, path, body)

  defp request(config, method, path, body) do
    url = config.base_url <> "/api/v1" <> path

    # `retry: false` — le retry HTTP est délégué au caller :
    # `Fleet.Pilot.Poller` a son propre backoff exponentiel + jitter
    # (5min cap, anti-thundering-herd), et `AutoDispatcher` traite un
    # event à la fois en serial. Le retry built-in Req (1s/2s/4s sur
    # 5xx) duplicaterait cette logique + ralentirait les tests d'erreur
    # de 7s par cas.
    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "token " <> config.token},
          {"accept", "application/json"}
        ],
        receive_timeout: 10_000,
        retry: false
      ]
      |> maybe_put(:json, body)
      |> Keyword.merge(config.req_options)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================
  # Config resolution
  # ============================================================

  defp resolve_config(opts) do
    env = Application.get_env(:fleet_pilot, :forge, [])
    merged = Keyword.merge(env, opts)

    with {:ok, base_url} <- fetch_required(merged, :base_url),
         {:ok, token} <- resolve_token(merged) do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         token: token,
         req_options: Keyword.get(merged, :req_options, [])
       }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:config, {:missing, key}}}
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case Keyword.get(opts, :token_file) || default_token_file() do
          nil ->
            {:error, {:config, :no_token_source}}

          path ->
            case File.read(path) do
              {:ok, content} -> {:ok, String.trim(content)}
              {:error, reason} -> {:error, {:config, {:token_file, path, reason}}}
            end
        end
    end
  end

  defp default_token_file do
    case System.user_home() do
      nil -> nil
      home -> Path.join(home, ".gitea_token")
    end
  end
end
