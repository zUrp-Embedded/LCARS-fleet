defmodule Fleet.Spawner.SeedStore do
  @moduledoc """
  Seed-store des pods (chantier pod-seed, volet 2). À la mort d'un pod-PROJET, son JSONl de session
  ACTIF (sa mémoire) est checkpointé vers `<seed_root>/<projet>/pods/<role>.jsonl` + une carte
  `<role>.json` (`{uuid, slug}`) pour le rappel ultérieur (`--resume`). Cf.
  `DOC-pod-session-seed-mechanism`. **Best-effort** : un échec de checkpoint ne tue JAMAIS le pod
  (le seed est un bonus de mémoire, pas une dépendance du lifecycle).

  - `seed_root` : `:fleet_spawner, :seed_store_root` (défaut `/home/projects.work`).
  - JSONl ACTIF = le plus récemment modifié sous `<pod_dir>/.claude/projects/*/` — gère la rotation
    d'UUID par `/clear` (on prend la session VIVANTE, pas l'UUID de lancement `state.session_id`).
  - La carte `<role>.json` porte le `uuid` + le `slug` (cwd-slug) : le rappel restaure le JSONl à
    `projects/<slug>/<uuid>.jsonl` puis `--resume <uuid>` (cf. volet 3).

  NB git : le `cp` dépose le seed ; la mise sous git du work repo est un geste SÉPARÉ (hors hot-path
  du teardown — pas de `git` dans la mort d'un pod).
  """
  require Logger

  @spec checkpoint(Path.t(), String.t(), String.t()) :: :ok | :none | {:error, term()}
  def checkpoint(pod_dir, projet, role)
      when is_binary(pod_dir) and is_binary(projet) and is_binary(role) do
    case latest_jsonl(pod_dir) do
      :none ->
        :none

      {:ok, jsonl} ->
        uuid = Path.basename(jsonl, ".jsonl")
        slug = Path.basename(Path.dirname(jsonl))
        dest_dir = Path.join([root(), projet, "pods"])
        File.mkdir_p!(dest_dir)
        File.cp!(jsonl, Path.join(dest_dir, "#{role}.jsonl"))

        File.write!(
          Path.join(dest_dir, "#{role}.json"),
          Jason.encode!(%{"uuid" => uuid, "slug" => slug, "projet" => projet, "role" => role})
        )

        Logger.info("SeedStore: checkpoint #{projet}/#{role} (uuid=#{uuid}) → #{dest_dir}")
        :ok
    end
  rescue
    e ->
      Logger.warning("SeedStore: checkpoint #{projet}/#{role} ÉCHEC (non-fatal) : #{inspect(e)}")
      {:error, e}
  end

  # JSONl actif = le plus récent sous .claude/projects/*/*.jsonl. Robuste aux fichiers volatils.
  defp latest_jsonl(pod_dir) do
    [pod_dir, ".claude", "projects", "*", "*.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn f ->
      case File.stat(f, time: :posix) do
        {:ok, %{mtime: m}} -> [{f, m}]
        _ -> []
      end
    end)
    |> case do
      [] -> :none
      list -> {:ok, list |> Enum.max_by(fn {_f, m} -> m end) |> elem(0)}
    end
  end

  defp root, do: Application.get_env(:fleet_spawner, :seed_store_root, "/home/projects.work")
end
