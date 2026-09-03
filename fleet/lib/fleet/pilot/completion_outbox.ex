defmodule Fleet.Pilot.CompletionOutbox do
  @moduledoc """
  Durable journal of the step_run completions still owed to the forge — 6-127.

  ## Ce qu'il tient, et ce que la chaine tient deja

  La chaine de `StepRunCompleter` est DEJA concue pour la reprise : son ordre est choisi pour ca
  (verrou leve EN DERNIER, apres la route gravee), et ses ecritures sont idempotentes — dedup du
  commentaire par signature, push idempotent, write-ops rejouables. Son `@moduledoc` l'annonce :
  *« recovery replays the sequence, the done steps skip »*.

  **Mais rien ne rejoue tout seul.** Le resultat de l'agent est consomme par `TaskQueue` — l'item
  passe `completed` des que la diffusion locale rend `:ok` — et le pod est relache. Sans journal,
  une Task de completion qui meurt entre-temps emporte la SEULE copie du resultat : le verrou reste
  sur la forge, le poller reclame l'orphelin apres sa grace, et **un agent refait le travail**.
  Degradation bornee, mais la phrase du completer promet alors plus que ce que la fleet tient.

  Ce module est l'autre moitie : le resultat est POSE ICI avant que la chaine ne tourne, et RETIRE
  quand elle a fini. Ce qui reste au demarrage est, par construction, une completion due.

  ## Pourquoi un fichier, alors que la file de taches est EPHEMERE en production

  Ce ne sont pas le meme objet et la distinction est le coeur de la fiche. La file de taches est
  ephemere pour qu'aucune tache PERIMEE ne survive a un redemarrage — la verite de « quel travail
  existe » vit sur la forge (doctrine D1). Ici on ne journalise pas du travail a faire : on
  journalise un travail DEJA FAIT PAR L'AGENT dont la trace forge n'est pas encore complete. Le
  perdre ne fait pas oublier une tache, ca fait REFAIRE un run d'agent — exactement ce que la
  preuve de sortie de 6-127 interdit. Meme nature que `Spawner.StateFs` et `SeedStore`, qui
  persistent deja pour la reprise.

  ## Forme

  Un fichier JSON par completion, nomme d'apres le `work_item_id` (l'identite que la fiche nomme),
  sous `~/.lcars/completion-outbox/`. Ecriture atomique (tmp + rename) : une entree lue est
  toujours complete.

  ⚠ `work_item_id` PEUT MANQUER dans la charge utile (les chemins qui ne passent pas par la file).
  On ne fabrique pas d'identite dans ce cas : `put/1` rend `{:error, :no_work_item_id}` et
  l'appelant continue SANS journal. Une completion non journalisee se comporte comme avant — pas
  de reprise, degradation bornee — et c'est preferable a une cle inventee qui ferait dedupliquer
  deux completions distinctes.
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
      # `fetch_env` + defaut explicite, JAMAIS `get_env/3` : le troisieme argument de `get_env/3`
      # est evalue a CHAQUE appel, et `Layout.state_dir/0` porte un `System.user_home!()` qui leve.
      # Meme piege que 6-017, meme parade.
      :error -> Path.join(Fleet.Layout.state_dir(), @dirname)
    end
  end

  @doc """
  Journalise une completion due. `{:error, :no_work_item_id}` si la charge n'en porte pas.

  L'appelant ne doit PAS traiter une erreur ici comme fatale : la completion se deroule de toute
  facon, elle ne sera simplement pas reprenable.
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

  @doc "Retire une completion acquittee. Absente = deja retiree : `:ok` (l'appel est idempotent)."
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
  Les completions dues, dans un ordre stable (par nom de fichier).

  Une entree illisible ou malformee est SIGNALEE et ecartee, jamais silencieusement sautee : elle
  represente un resultat d'agent qu'on ne saura pas reprendre, et c'est exactement le fait que
  6-127 refuse de laisser muet. Elle reste sur le disque — l'effacer detruirait la seule piece a
  conviction.
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

  # `work_item_id` est l'identite que 6-127 nomme, et c'est celle de la file : deux completions du
  # meme item sont la MEME completion, une reprise ne doit pas en creer une seconde.
  defp key_of(payload) do
    case payload["work_item_id"] || payload[:work_item_id] do
      id when is_binary(id) and id != "" -> Fleet.Slug.cast(id) |> ok_or_nil()
      _ -> nil
    end
  end

  defp ok_or_nil({:ok, slug}), do: slug
  defp ok_or_nil(_), do: nil

  defp path_for(key), do: Path.join(root(), key <> ".json")

  # tmp + rename dans LE MEME repertoire : le rename est atomique sur le meme systeme de fichiers,
  # donc une entree lue est toujours complete. Un tmp orphelin (crash entre write et rename) ne
  # finit pas en `.json` et n'est donc jamais lu comme une completion due.
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
