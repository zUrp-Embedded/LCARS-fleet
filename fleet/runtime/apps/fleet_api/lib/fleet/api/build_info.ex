defmodule Fleet.API.BuildInfo do
  @moduledoc """
  Version du build servi — **constatable, pas déduite**.

  Quel commit tourne ? Cette donnée doit être lisible sans inspecter le repo
  (une release est auto-contenue : ERTS bundlé, priv embarqué, **pas de repo
  git ni de Mix au runtime**). `current/0` rend le SHA git court + un flag
  `dirty` + la `ref`, et un champ `:source` qui dit **d'où vient l'info** —
  pas un fallback masqué, une provenance explicite et honnête.

  ## Une source selon le contexte (le `:source` la rend explicite)

    1. `:release` — le fichier `priv/build_info.txt` existe : il a été embarqué
       au `mix release` (cf. `write_release_file/1`, capturé sur la machine de
       build où git existe). On le lit, point. La release ne touche jamais git.
    2. `:working_tree` — pas de fichier embarqué (mode source/dev) : on
       interroge git LIVE (`rev-parse --short HEAD`, `--abbrev-ref HEAD`,
       `status --porcelain`) dans le cwd du BEAM (le repo).
    3. `:unknown` — ni fichier, ni git exploitable (git absent, pas un repo,
       sandbox release sans priv) : `%{sha: "unknown", dirty: false, ref: nil}`.

  ## Totale / fail-safe

  C'est un outil d'**observabilité** : il ne doit JAMAIS lever ni empêcher la
  fleet de booter. `System.cmd("git", …)` peut lever (git absent →
  `ErlangError :enoent`) ou sortir en erreur (pas un repo) ; tout chemin
  d'échec retombe sur `:unknown`. `current/0` est totale par construction.

  ## Cache

  `current/0` est appelée au boot (log) ET potentiellement par requête
  (endpoint `/api/version`). Le résultat est mémoïsé en `:persistent_term`
  (clé `{__MODULE__, :info}`) au 1er appel — on ne spawne pas un `git` par
  requête. En mode `:working_tree`/dev le SHA peut changer entre deux boots
  (recompile relance le BEAM → 1er appel recalcule) : acceptable, le cache
  n'est volontairement PAS invalidable à chaud (le besoin n'existe pas).

  Module de **données + fonctions pures** : aucun process (pas d'état runtime
  porté, pas de concurrence, pas d'isolation de faute). `:persistent_term` est
  un cache de table, pas un process.
  """

  @persistent_key {__MODULE__, :info}

  @type t :: %{
          sha: String.t(),
          dirty: boolean(),
          ref: String.t() | nil,
          source: :release | :working_tree | :unknown
        }

  @doc """
  Version du build servi, mémoïsée. Totale : ne lève jamais, retombe sur
  `:unknown` à tout échec.
  """
  @spec current() :: t()
  def current do
    case :persistent_term.get(@persistent_key, :miss) do
      :miss ->
        info = safe_resolve()
        :persistent_term.put(@persistent_key, info)
        info

      info ->
        info
    end
  end

  @doc """
  Step de `mix release` : capture le SHA sur la machine de build (git présent)
  et écrit `priv/build_info.txt` DANS le release assemblé, avant le `:tar`.

  Le path de destination est calculé exactement comme Mix copie l'app
  (`<release.path>/lib/<app>-<vsn>/priv`, cf. `Mix.Release` `copy_app`) — pas
  un glob bricolé. Le runtime relira ce fichier via
  `Application.app_dir(:fleet_api, "priv/build_info.txt")` → `source: :release`.

  Best-effort sur la capture : si git échoue au build, on écrit des facts
  `unknown` plutôt que de casser la construction de la release.
  """
  @spec write_release_file(Mix.Release.t()) :: Mix.Release.t()
  def write_release_file(%Mix.Release{} = release) do
    facts =
      case git_facts() do
        {:ok, f} -> f
        :error -> %{sha: "unknown", dirty: false, ref: nil}
      end

    properties = Map.fetch!(release.applications, :fleet_api)
    vsn = Keyword.fetch!(properties, :vsn)
    priv_dir = Path.join([release.path, "lib", "fleet_api-#{vsn}", "priv"])

    File.mkdir_p!(priv_dir)
    File.write!(Path.join(priv_dir, "build_info.txt"), serialize(facts))

    release
  end

  @doc """
  Lit + parse un fichier `build_info.txt` (le seam testable du chemin
  `:release`). `{:ok, info}` si le fichier existe et est lisible ; `:error`
  sinon (→ `current/0` bascule sur `working_tree`). Le parse est total :
  champ absent ⇒ défaut (`sha: "unknown"`, `dirty: false`, `ref: nil`).
  """
  @spec read_release_file(Path.t()) :: {:ok, t()} | :error
  def read_release_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, _} -> :error
    end
  end

  # --- résolution interne ---------------------------------------------------

  # Garde-fou final de la totalité : tout raise/throw imprévu → :unknown (le
  # cache mémoïsera ce :unknown, on ne re-tente pas git à chaque requête).
  defp safe_resolve do
    resolve()
  rescue
    _ -> unknown()
  catch
    _, _ -> unknown()
  end

  defp resolve do
    case read_release_file(release_file_path()) do
      {:ok, info} -> info
      :error -> resolve_working_tree()
    end
  end

  defp release_file_path do
    Application.app_dir(:fleet_api, "priv/build_info.txt")
  end

  defp resolve_working_tree do
    case git_facts() do
      {:ok, facts} -> Map.put(facts, :source, :working_tree)
      :error -> unknown()
    end
  end

  # Facts git bruts (sha/dirty/ref) partagés par le build (write_release_file)
  # et le runtime (resolve_working_tree). `:error` si HEAD est injoignable
  # (git absent / pas un repo).
  defp git_facts do
    case git(["rev-parse", "--short", "HEAD"]) do
      {:ok, sha} -> {:ok, %{sha: sha, dirty: dirty?(), ref: working_tree_ref()}}
      :error -> :error
    end
  end

  defp working_tree_ref do
    case git(["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, ref} -> ref
      :error -> nil
    end
  end

  defp dirty? do
    case git(["status", "--porcelain"]) do
      {:ok, ""} -> false
      {:ok, _nonempty} -> true
      :error -> false
    end
  end

  # Wrapper totale autour de git. `stderr_to_stdout` + match sur l'exit status
  # pour « pas un repo » ; `rescue` pour « git absent » (System.cmd lève
  # ErlangError :enoent quand l'exécutable est introuvable).
  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _nonzero} -> :error
    end
  rescue
    _ -> :error
  end

  defp unknown, do: %{sha: "unknown", dirty: false, ref: nil, source: :unknown}

  # --- (dé)sérialisation du fichier embarqué --------------------------------
  # Format `clef=valeur` une par ligne — lisible à l'œil (et par le case bash
  # `fleet_v2 version`), trivial à parser, total.

  defp serialize(%{sha: sha, dirty: dirty, ref: ref}) do
    "sha=#{sha}\ndirty=#{dirty}\nref=#{ref}\n"
  end

  defp parse(content) do
    fields =
      content
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)

    %{
      sha: Map.get(fields, "sha", "unknown"),
      dirty: Map.get(fields, "dirty") == "true",
      ref: blank_to_nil(Map.get(fields, "ref")),
      source: :release
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
