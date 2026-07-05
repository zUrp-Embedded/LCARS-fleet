defmodule Fleet.TaskQueue.Store do
  @moduledoc """
  Persistence `state.json` du broker — sérialisation + FS, extrait de
  `Fleet.TaskQueue.Server` (le GenServer garde l'orchestration : QUAND persister,
  QUOI recharger ; ce module ne sait QUE lire/écrire une map de work items).

  Aucun process, aucun state GenServer : les deux opérations prennent un `path`
  et une map `%{id => %WorkItem{}}` en arguments explicites.

  ## Contrat

    * `save/2` — écriture ATOMIQUE (tmp + rename) du schéma versionné `v: 1`.
      **Best-effort côté WRITE** : un échec d'écriture est loggé **error**
      (durabilité du point de recovery rompue) mais rend `:ok` quand même —
      on ne crashe pas le broker sur un blip disque ; la réconciliation passe
      par le rail forge-driven (re-dispatch depuis l'état forge), pas par
      cette persistance locale.
    * `load/1` — **fail-loud côté READ** : un `state.json` non-parseable, de
      version inattendue ou portant un work item non-désérialisable rend
      `{:corrupt, found}` (jamais un drop silencieux d'une partie de l'état) ;
      le Server en fait un fallback non-bloquant (state vide + event
      `:"state.corrupt"`).
    * `default_path/0` — où vit `state.json` quand l'appelant ne le fixe pas.

  La décision de NE PAS persister (`persist: false`, mode prod éphémère) ou de
  charger à vide reste dans le Server : elle dépend de ses options de boot, pas
  du format du fichier.
  """

  require Logger

  alias Fleet.TaskQueue.WorkItem

  @doc """
  Chemin par défaut de `state.json` : config `:fleet_task_queue, :state_path`,
  sinon `~/.lcars/task-queue/state.json`.

  Le fleet tourne sous l'humain → défaut home-relatif `~/.lcars/task-queue`, comme le pod
  state_fs_root (`Fleet.Spawner.Pod.default_state_fs_root`) : un `/var/lib/lcars` en dur ne
  serait pas ownable hors du compte `lcars`. HOME irrésoluble = runtime cassé → fail-loud
  (`System.user_home!()` raise), jamais un chemin fabriqué : l'état .lcars ne doit pas se
  disperser en silence.
  """
  @spec default_path() :: Path.t()
  def default_path do
    Application.get_env(
      :fleet_task_queue,
      :state_path,
      Path.join(System.user_home!(), ".lcars/task-queue/state.json")
    )
  end

  @doc """
  Écrit la map de work items dans `path` — écriture atomique (tmp + rename),
  schéma `%{"v" => 1, "work_items" => %{id => WorkItem.to_map(t)}}`.

  Best-effort : rend TOUJOURS `:ok`. Un échec d'écriture rompt la durabilité du point de
  recovery cross-restart — c'est une ERREUR loggée, pas un warning : la queue RAM avance
  mais state.json diverge → un restart relirait un état stale. On NE crashe PAS le broker
  (un blip disque transitoire ne doit pas tuer les work items en vol) ; la réconciliation
  passe par le rail forge-driven. Le breach devient LOUD (error-level → monitoring), plus
  de dégradé silencieux.
  """
  @spec save(Path.t(), %{optional(String.t()) => WorkItem.t()}) :: :ok
  def save(path, work_items) when is_binary(path) and is_map(work_items) do
    data = %{
      "v" => 1,
      "work_items" => Map.new(work_items, fn {id, t} -> {id, WorkItem.to_map(t)} end)
    }

    try do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(data))
      File.rename!(tmp, path)
    rescue
      e ->
        Logger.error(
          "Store: persist ÉCHEC — durabilité du point de recovery rompue (non-fatal, " <>
            "réconciliation forge-driven ; path=#{path}): #{inspect(e)}"
        )
    end

    :ok
  end

  @doc """
  Lit et désérialise `state.json` depuis `path`.

    * `:empty` — fichier absent (`:enoent`) : premier boot, rien à recharger.
    * `{:ok, %{id => %WorkItem{}}}` — schéma `v: 1` valide, tous les work items désérialisés.
    * `{:corrupt, found}` — fichier illisible, JSON non-parseable, version ≠ 1, ou un
      work item non-désérialisable (state corrompu / champ requis absent). Fail-loud :
      on HALTE sur le 1er work item corrompu plutôt que de le FILTRER (état tronqué en
      silence) ; `WorkItem.from_map` rend `{:error, _}` au lieu de RAISER (le fallback
      `:corrupt` du Server tient).
  """
  @spec load(Path.t()) ::
          :empty | {:ok, %{optional(String.t()) => WorkItem.t()}} | {:corrupt, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> decode_state(content)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:corrupt, reason}
    end
  end

  defp decode_state(content) do
    case Jason.decode(content) do
      {:ok, %{"v" => 1, "work_items" => work_items_map}} when is_map(work_items_map) ->
        decode_work_items(work_items_map)

      {:ok, %{"v" => v}} ->
        {:corrupt, v}

      _ ->
        {:corrupt, :unparseable}
    end
  end

  # fail-loud : une tâche non-désérialisable → `{:corrupt, ...}`, PAS un drop silencieux.
  # `reduce_while` HALTE sur la 1re tâche corrompue plutôt que de la FILTRER (état tronqué
  # en silence).
  defp decode_work_items(work_items_map) do
    Enum.reduce_while(work_items_map, {:ok, %{}}, fn {id, tm}, {:ok, acc} ->
      case WorkItem.from_map(tm) do
        {:ok, t} -> {:cont, {:ok, Map.put(acc, id, t)}}
        {:error, reason} -> {:halt, {:corrupt, {:work_item, id, reason}}}
      end
    end)
  end
end
