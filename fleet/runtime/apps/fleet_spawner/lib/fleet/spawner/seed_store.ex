defmodule Fleet.Spawner.SeedStore do
  @moduledoc """
  Seed-store des pods. À la mort d'un pod-PROJET, le PREMIER ROUND de son JSONl de session
  ACTIF (sa mémoire) est checkpointé vers `<seed_root>/<projet>/pods/<role>.jsonl` + une workflow_map
  `<role>.json` (`{uuid, slug}`) pour le rappel ultérieur (`--resume`).
  **Best-effort** : un échec de checkpoint ne tue JAMAIS le pod
  (le seed est un bonus de mémoire, pas une dépendance du lifecycle).

  - `seed_root` : `:fleet_spawner, :seed_store_root` (défaut `/home/projects.work`).
  - L'`uuid` de la workflow_map = le BUILDER DÉTERMINISTE du slot Desktop (le `session_id` pré-alloué au
    spawn, passé en argument) : c'est la SOURCE UNIQUE de l'identité du pod. Il n'est PAS dérivé de
    l'UUID du jsonl vivant — un `/clear` rotate l'UUID vivant, et un seed qui le suivrait ferait
    reprendre au pod un slot bâtard (≠ builder) au recall.
  - Le CONTENU et le `slug` viennent, eux, du jsonl ACTIF = le plus récemment modifié sous
    `<pod_dir>/.claude/projects/*/` (la session VIVANTE, robuste à la rotation `/clear`). Sans jsonl
    vivant (`:none`), il n'y a aucun contenu à checkpointer → rien n'est écrit.
  - La workflow_map `<role>.json` porte donc l'`uuid` (= builder) + le `slug` (cwd-slug du jsonl vivant) :
    le rappel restaure le JSONl à `projects/<slug>/<uuid>.jsonl` puis `--resume <uuid>`.

  NB git : le `cp` dépose le seed ; la mise sous git du work repo est un geste SÉPARÉ (hors hot-path
  du teardown — pas de `git` dans la mort d'un pod).
  """
  require Logger

  @doc """
  Checkpointe le seed d'un pod-PROJET mourant. `session_id` = le BUILDER DÉTERMINISTE du slot
  Desktop (le `session_id` pré-alloué au spawn) : c'est l'`uuid` stocké dans la workflow_map, SOURCE UNIQUE
  de l'identité du pod — PAS l'UUID du jsonl vivant (qu'un `/clear` aurait pu rotater). Le contenu
  (premier round) et le `slug` viennent du jsonl ACTIF. Sans jsonl vivant → `:none`.
  Best-effort : confinement des noms + `{:error, _}` non-fatal.
  """
  @spec checkpoint(Path.t(), String.t(), String.t(), String.t()) ::
          :ok | :none | {:error, term()}
  def checkpoint(pod_dir, projet, role, session_id)
      when is_binary(pod_dir) and is_binary(projet) and is_binary(role) and is_binary(session_id) do
    # `projet` ET `role` sont des COMPOSANTS de chemin du seed-store (`<root>/<projet>/pods/<role>.jsonl`).
    # Ils viennent de `rc_name` (entrée de dispatch/recall, non maîtrisée par construction) : un `..`/`/`
    # traverserait hors du store (écrire un `.jsonl` arbitraire de l'hôte). On caste les deux en slug et on
    # confine le dossier de destination sous la racine AVANT tout `mkdir_p!`/`write!` — un nom malformé
    # n'atteint jamais le FS (`{:error, _}` best-effort, le checkpoint est un bonus de mémoire non-fatal).
    with {:ok, projet_slug} <- Fleet.Slug.cast(projet),
         {:ok, role_slug} <- Fleet.Slug.cast(role),
         {:ok, projet_dir} <- Fleet.Slug.confined_join(root(), projet_slug) do
      do_checkpoint(pod_dir, projet_slug, role_slug, session_id, Path.join(projet_dir, "pods"))
    else
      {:error, reason} ->
        Logger.warning(
          "SeedStore: checkpoint refusé (nom non confiné) projet=#{inspect(projet)} role=#{inspect(role)} : #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp do_checkpoint(pod_dir, projet, role, session_id, dest_dir) do
    case latest_jsonl(pod_dir) do
      :none ->
        :none

      {:ok, jsonl} ->
        # L'uuid stocké = le BUILDER DÉTERMINISTE (`session_id` pré-alloué au spawn), source UNIQUE
        # de l'identité du slot Desktop. On NE le dérive PAS de `Path.basename(jsonl)` : un `/clear`
        # rotate l'UUID du jsonl vivant, et un seed qui le suivrait ferait reprendre un slot bâtard
        # (≠ builder) au recall. Seuls le `slug` (cwd-slug) et le CONTENU viennent du jsonl vivant.
        uuid = session_id
        slug = Path.basename(Path.dirname(jsonl))
        File.mkdir_p!(dest_dir)

        # On ne garde QUE le PREMIER ROUND (seed minimal résumable = le setup/brief initial du pod),
        # PAS la session entière — le travail se re-dérive de la forge (axiome source-unique).
        # Ce sous-ensemble `--resume` correctement avec le seul contexte du round 1.
        File.write!(Path.join(dest_dir, "#{role}.jsonl"), first_round(jsonl))

        File.write!(
          Path.join(dest_dir, "#{role}.json"),
          Jason.encode!(%{"uuid" => uuid, "slug" => slug, "projet" => projet, "role" => role})
        )

        Logger.info(
          "SeedStore: checkpoint #{projet}/#{role} (uuid=#{uuid} = builder déterministe) → #{dest_dir}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("SeedStore: checkpoint #{projet}/#{role} ÉCHEC (non-fatal) : #{inspect(e)}")
      {:error, e}
  end

  # Premier round = les lignes jusqu'au 1er event `assistant` INCLUS (brief/setup + 1ʳᵉ réponse).
  # C'est le seed minimal résumable ; le reste de la session est jeté (re-dérivable forge).
  defp first_round(jsonl_path) do
    jsonl_path
    |> File.stream!()
    |> Enum.reduce_while([], fn line, acc ->
      acc = [line | acc]

      case Jason.decode(line) do
        {:ok, %{"type" => "assistant"}} -> {:halt, acc}
        _ -> {:cont, acc}
      end
    end)
    |> Enum.reverse()
    |> Enum.join()
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

  @doc """
  Lit la workflow_map d'un seed checkpointé. `{:ok, %{uuid, slug, jsonl}}` (jsonl = chemin du seed dans le
  store) si la workflow_map ET le JSONl existent ; sinon `:none`.
  """
  @spec read_map(String.t(), String.t()) :: {:ok, map()} | :none
  def read_map(projet, role) when is_binary(projet) and is_binary(role) do
    # Lecture-feuille du seed-store : `projet`/`role` sont des composants de chemin. Mêmes castes que
    # `checkpoint/4` (un `recall(projet, role)` exposé prend ces deux args d'un appelant) → un nom non
    # confiné rend `:none` (seed introuvable) plutôt que de lire un `.json`/`.jsonl` arbitraire de l'hôte.
    with {:ok, projet_slug} <- Fleet.Slug.cast(projet),
         {:ok, role_slug} <- Fleet.Slug.cast(role),
         {:ok, projet_dir} <- Fleet.Slug.confined_join(root(), projet_slug),
         dir = Path.join(projet_dir, "pods"),
         jsonl = Path.join(dir, "#{role_slug}.jsonl"),
         {:ok, raw} <- File.read(Path.join(dir, "#{role_slug}.json")),
         {:ok, %{"uuid" => uuid} = m} <- Jason.decode(raw),
         true <- File.exists?(jsonl) do
      {:ok, %{uuid: uuid, slug: m["slug"], jsonl: jsonl}}
    else
      _ -> :none
    end
  end

  @doc """
  Restaure un seed dans le HOME d'un pod de rappel : `cp` le JSONl à
  `<pod_dir>/.claude/projects/<slugify(cwd)>/<uuid>.jsonl`. Le `cwd` est celui du pod de rappel
  (slug recalculé) → `--resume <uuid>` (cwd = `cwd`) retrouve la session. Renvoie `{:ok, dest}`.
  """
  @spec restore(Path.t(), Path.t(), Path.t(), String.t()) :: {:ok, Path.t()}
  def restore(seed_jsonl, pod_dir, cwd, uuid)
      when is_binary(seed_jsonl) and is_binary(pod_dir) and is_binary(cwd) and is_binary(uuid) do
    # `cwd` est déjà confiné par `slugify` (tout hors `[A-Za-z0-9-]` → `-`, donc ni `/` ni `..`). Le
    # `uuid`, lui, vient du `.json` du seed (`read_map`) : si ce fichier portait un `uuid` hostile
    # (`../../x`), il s'interpolerait dans la FEUILLE et écrirait hors du dossier `projects/<slug>/`. On
    # confine donc le `dest` résolu sous le pod_dir AVANT le `cp!` — fail-loud (raise) si évasion (le
    # caller `maybe_recall_restore` rabat ce raise sur `transition_failed`, le pod ne lance pas).
    dir = Path.join([pod_dir, ".claude", "projects", slugify(cwd)])
    File.mkdir_p!(dir)
    dest = Path.expand(Path.join(dir, "#{uuid}.jsonl"))

    unless Fleet.Slug.under_root?(dest, pod_dir) do
      raise ArgumentError,
            "SeedStore.restore: uuid non confiné (#{inspect(uuid)}) — évasion refusée"
    end

    File.cp!(seed_jsonl, dest)
    {:ok, dest}
  end

  @doc """
  Slug claude d'un `cwd` : chaque caractère hors `[A-Za-z0-9-]` → `-` (PAS de collapse des `-`).
  Ex. `/home/x/pod_a-b` → `-home-x-pod-a-b`.

  COMPAT VENDOR — reproduit BIT POUR BIT l'algo de slugification de Claude Code (prouve v2.1.183, cf.
  seed_store_test). C'est ce qui permet de retrouver `~/.claude/projects/<slug>/<uuid>.jsonl` au resume.
  NE PAS remplacer par `Fleet.Slug` ni `PodId.component` (charsets differents) : un slug qui ne matche pas
  celui de Claude pointe sur un mauvais dossier -> resume casse. Domaine fige par un systeme externe.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(path), do: String.replace(path, ~r/[^A-Za-z0-9-]/, "-")

  defp root, do: Application.get_env(:fleet_spawner, :seed_store_root, "/home/projects.work")
end
