defmodule Fleet.Pilot.CompletionOutbox do
  @moduledoc """
  Journal des resultats d'agent dont la completion forge reste a reprendre.

  La file ephemere de taches ne doit pas restaurer du travail perime ; ce journal
  conserve du travail deja produit, pour eviter de refaire un run apres interruption.
  StepRunConsumer ecrit avant completion et retire sur retour ok, skip ou escalation.
  En mode offload, ok peut seulement signifier admission de la Task : l'entree est alors
  retiree avant son resultat forge, qui n'est pas acquitte dans ce journal.
  Un retrait rate peut laisser une completion deja terminee : pending n'est pas une preuve
  que chaque effet reste du. La reprise depend des operations du completer, sans garantie
  globale d'execution exactement une fois.

  Un JSON par work_item_id valide sous ~/.lcars/completion-outbox/. Sans cette identite,
  put refuse et le consommateur continue sans journal ; aucune cle de remplacement
  n'est inventee. Le renommage du temporaire est atomique, sans fsync ni protection
  contre deux ecrivains du meme item partageant le meme temporaire.
  """

  require Logger

  @dirname "completion-outbox"

  @typedoc "La charge utile `pod.completed` telle qu'elle arrive au consommateur."
  @type payload :: map()

  @doc "Racine du journal. Surchargeable par `:lcars_fleet, :pilot_completion_outbox_root` (test)."
  @spec root() :: Path.t()
  def root do
    case Application.fetch_env(:lcars_fleet, :pilot_completion_outbox_root) do
      {:ok, path} -> path
      # Eviter d'evaluer Layout.state_dir/System.user_home! quand une surcharge est presente.
      :error -> Path.join(Fleet.Layout.state_dir(), @dirname)
    end
  end

  @doc """
  Ecrit le resultat sous son work_item_id ; identite absente ou invalide donne
  `{:error, :no_work_item_id}`. Les erreurs retournees n'empechent pas le consommateur
  de completer, mais cette tentative n'ajoute alors aucune entree de reprise.
  """
  @spec put(payload()) :: {:ok, String.t()} | {:error, term()}
  def put(payload) when is_map(payload) do
    case key_of(payload) do
      nil ->
        {:error, :no_work_item_id}

      key ->
        with :ok <- File.mkdir_p(root()),
             {:ok, json} <- Jason.encode(payload),
             :ok <- atomic_write(path_for(key), json) do
          {:ok, key}
        end
    end
  end

  @doc "Tente le retrait ; absence et erreur de fichier rendent :ok, avec avertissement sur erreur."
  @spec delete(payload() | String.t()) :: :ok
  def delete(key) when is_binary(key) do
    case File.rm(path_for(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> log_and_ok(key, reason)
    end
  end

  def delete(payload) when is_map(payload) do
    case key_of(payload) do
      nil -> :ok
      key -> delete(key)
    end
  end

  @doc """
  Lit les fichiers .json dans l'ordre de leurs noms. JSON non-map ou entree illisible :
  erreur logguee, fichier conserve, entree omise. Une map n'est pas validee comme payload.
  Racine absente : liste vide ; autre erreur de lecture : log et liste vide.
  """
  @spec pending() :: [payload()]
  def pending do
    case File.ls(root()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.flat_map(&read_entry/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error(
          "CompletionOutbox: journal ILLISIBLE (#{root()} : #{inspect(reason)}) — aucune " <>
            "completion en attente ne sera reprise a ce demarrage"
        )

        []
    end
  end

  defp read_entry(name) do
    path = Path.join(root(), name)

    with {:ok, body} <- File.read(path),
         {:ok, %{} = payload} <- Jason.decode(body) do
      [payload]
    else
      other ->
        Logger.error(
          "CompletionOutbox: entree ILLISIBLE #{path} (#{inspect(other)}) — un resultat d'agent " <>
            "ne sera pas repris. Le fichier est CONSERVE (seule piece a conviction)."
        )

        []
    end
  end

  # Une meme identite de file remplace la meme entree ; ne pas deduire la cle du ticket.
  defp key_of(payload) do
    case payload["work_item_id"] || payload[:work_item_id] do
      id when is_binary(id) and id != "" -> Fleet.Slug.cast(id) |> ok_or_nil()
      _ -> nil
    end
  end

  defp ok_or_nil({:ok, slug}), do: slug
  defp ok_or_nil(_), do: nil

  defp path_for(key), do: Path.join(root(), key <> ".json")

  # Meme repertoire pour le renommage ; pending ignore les .tmp orphelins.
  # Le nom temporaire est partage pour une meme cle, sans verrou ni synchronisation disque.
  defp atomic_write(path, body) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp log_and_ok(key, reason) do
    Logger.warning(
      "CompletionOutbox: retrait impossible pour #{key} (#{inspect(reason)}) — l'entree sera " <>
        "rejouee au prochain demarrage ; la chaine de completion est idempotente, donc sans effet"
    )

    :ok
  end
end
