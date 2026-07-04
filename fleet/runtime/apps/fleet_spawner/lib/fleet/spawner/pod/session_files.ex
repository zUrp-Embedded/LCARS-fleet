defmodule Fleet.Spawner.Pod.SessionFiles do
  @moduledoc """
  Localisation des JSONL de session claude d'un pod — île de LECTURE FS partagée.

  Un seul savoir, une seule autorité : les sessions du claude d'un pod vivent sous
  `<pod_dir>/.claude/projects/<cwd-slug>/<uuid>.jsonl` (un dossier par cwd-slug, un fichier
  append-only par session — layout posé par Claude Code, pas par la fleet). Trois consommateurs
  glob-aient ce chemin chacun de leur côté (GC de l'UUID au re-spawn, sonde de liveness, checkpoint
  seed-store) ; le glob vit maintenant ICI, chaque caller garde sa logique propre (rm / taille /
  contenu du plus-récent).

  Aucun state, aucun timer, aucune ÉCRITURE FS : que du `Path.wildcard` + `File.stat` (c'est ce qui
  le distingue de `Pod.Paths`, île de calcul PUR sans lecture FS — un glob n'y aurait pas sa place).
  Aucune dépendance vers `Fleet.Spawner.Pod` (pas de cycle).

  ## Contrat

  - `jsonl_paths(pod_dir)` — TOUS les jsonl de session du pod (tous cwd-slugs, tous uuids).
    Appelé par `Fleet.Spawner.SeedStore` (via `latest_jsonl/1`).
  - `jsonl_paths(pod_dir, session_id)` — les jsonl de CETTE session, tous cwd-slugs (le cwd-slug
    n'est pas connu de l'appelant : claude le dérive du cwd du REPL, d'où le `*`). Appelé par
    `Pod.Scaffold.gc_stale_session_jsonl` (GC) et `Pod.Liveness` (taille cumulée).
  - `latest_jsonl(pod_dir)` — le jsonl ACTIF (mtime le plus récent) → `{:ok, path}` | `:none`.
    Appelé par `Fleet.Spawner.SeedStore` (checkpoint du seed).
  """

  @doc """
  Chemins des jsonl de session sous `<pod_dir>/.claude/projects/*/`. Arité 1 = tous les jsonl du
  pod ; arité 2 = ceux de `session_id` (fichier `<session_id>.jsonl`, tous cwd-slugs). Rend `[]` si
  aucun (session pas encore écrite / pod_dir absent — `Path.wildcard` ne lève pas).
  """
  @spec jsonl_paths(Path.t(), String.t()) :: [Path.t()]
  def jsonl_paths(pod_dir, session_id \\ "*")
      when is_binary(pod_dir) and is_binary(session_id) do
    [pod_dir, ".claude", "projects", "*", "#{session_id}.jsonl"]
    |> Path.join()
    |> Path.wildcard()
  end

  @doc """
  Le jsonl ACTIF du pod = le plus récemment modifié sous `.claude/projects/*/` (la session VIVANTE,
  robuste à la rotation d'UUID d'un `/clear`). `:none` si aucun jsonl. Robuste aux fichiers
  volatils : un `File.stat` qui échoue (fichier disparu entre le glob et le stat) ignore l'entrée
  au lieu de lever.
  """
  @spec latest_jsonl(Path.t()) :: {:ok, Path.t()} | :none
  def latest_jsonl(pod_dir) when is_binary(pod_dir) do
    pod_dir
    |> jsonl_paths()
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
end
