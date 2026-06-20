defmodule Fleet.Pilot.IncidentRegistry do
  @moduledoc """
  Registre PERSISTANT cross-session des incidents système récupérés (#5.2).

  Sort la mémoire-d'échec de la SESSION (éphémère) pour l'ancrer dans le PROJET (durable) : un fail
  récupéré par re-roll est GRAVÉ ici ; sa RÉCURRENCE (session suivante) → escalade directe (pattern,
  pas random → root-cause à l'occurrence suivante). Couche : session exécute, **projet se souvient**,
  système (starfleet) répare.

  Stockage : fichier JSON `{signature → %{count, first_seen, last_seen, last_reason}}` dans `fleet/lcars`
  (repo/branche/path config-driven), read-modify-write via `ForgeClient.get_file`/`put_file` (sha).
  **PAS de process** : l'état EST le fichier forge (Iron Law — rien à garder en RAM entre appels).

  Signature : `"op:subject:reason"` — `subject` = pod_id normalisé (runs de chiffres → `N`, ex.
  `issue-N-engineer`) ; `reason` = catégorie (atom tel quel, ou `elem(0)` d'un tuple). Assez stable pour
  récurrer, assez fin pour ne pas tout confondre.

  **Fail-open** : registre illisible → `seen_before?/2` renvoie `false` (jamais de fausse escalade) ;
  `note/3` raté → log + `{:error, _}` (best-effort : la récupération a déjà eu lieu, le registre est une
  mémoire, pas un chemin critique).
  """
  require Logger

  @doc """
  Signature stable d'un incident. `op` = l'opération (`"wake"`…), `subject` = le pod_id, `reason` = la
  raison `{:error, reason}`. Ex : `signature("wake", "issue-42-engineer", :not_found)` →
  `"wake:issue-N-engineer:not_found"`.
  """
  @spec signature(String.t(), String.t(), term()) :: String.t()
  def signature(op, subject, reason) when is_binary(op) and is_binary(subject) do
    "#{op}:#{normalize(subject)}:#{reason_category(reason)}"
  end

  @doc "Vrai si `sig` a DÉJÀ été enregistré (récurrence). Fail-open : `false` si le registre est illisible."
  @spec seen_before?(String.t(), keyword()) :: boolean()
  def seen_before?(sig, opts \\ []) when is_binary(sig) do
    case load(opts) do
      {:ok, reg, _sha} -> Map.has_key?(reg, sig)
      _ -> false
    end
  end

  @doc "Grave/incrémente l'incident `sig` (commit). Best-effort : `{:error, _}` + log si l'écriture rate."
  @spec note(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def note(sig, reason, opts \\ []) when is_binary(sig) do
    {reg, sha} =
      case load(opts) do
        {:ok, reg, sha} -> {reg, sha}
        _ -> {%{}, nil}
      end

    now = opts[:now] || DateTime.to_iso8601(DateTime.utc_now())

    entry =
      reg
      |> Map.get(sig, %{"count" => 0, "first_seen" => now})
      |> Map.update("count", 1, &(&1 + 1))
      |> Map.put("last_seen", now)
      |> Map.put("last_reason", inspect(reason))

    save(Map.put(reg, sig, entry), sha, sig, opts)
  end

  # --- I/O forge (seams :get_file_fun / :put_file_fun ; défauts = ForgeClient) ---

  defp load(opts) do
    getter = Keyword.get(opts, :get_file_fun, &Fleet.Pilot.ForgeClient.get_file/3)

    case getter.(repo(opts), path(opts), ref: branch(opts)) do
      {:ok, %{content: content, sha: sha}} ->
        case JSON.decode(content) do
          {:ok, reg} when is_map(reg) -> {:ok, reg, sha}
          _ -> {:error, :bad_json}
        end

      {:error, _} = err ->
        err
    end
  end

  # sha présent ⇒ UPDATE ; sha nil ⇒ CREATE (put_file/maybe_put_sha gère le nil).
  defp save(reg, sha, sig, opts) do
    putter = Keyword.get(opts, :put_file_fun, &Fleet.Pilot.ForgeClient.put_file/4)
    put_opts = [branch: branch(opts), message: "ops(incident): #{sig}", sha: sha]

    case putter.(repo(opts), path(opts), JSON.encode!(reg), put_opts) do
      {:ok, _} ->
        :ok

      {:error, _} = err ->
        Logger.warning("IncidentRegistry: note #{sig} échouée (best-effort): #{inspect(err)}")
        err
    end
  end

  defp repo(opts),
    do: opts[:repo] || Application.get_env(:fleet_pilot, :incident_registry_repo, "fleet/lcars")

  defp branch(opts),
    do: opts[:branch] || Application.get_env(:fleet_pilot, :incident_registry_branch, "main")

  defp path(opts),
    do:
      opts[:path] ||
        Application.get_env(
          :fleet_pilot,
          :incident_registry_path,
          "work/ops/system-incidents.json"
        )

  defp normalize(subject), do: Regex.replace(~r/\d+/, subject, "N")

  defp reason_category(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_category(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason_category(elem(reason, 0))

  defp reason_category(reason), do: inspect(reason)
end
