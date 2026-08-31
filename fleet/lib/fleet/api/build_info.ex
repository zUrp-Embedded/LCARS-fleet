defmodule Fleet.API.BuildInfo do
  @moduledoc """
  Reports the served build's SHA, dirty flag, ref and provenance.

  Releases read the build-time `priv/api/build_info.txt`; source trees query
  Git through the bounded shell authority; failure returns an explicit
  `:unknown` result. `current/0` memoizes the result for the BEAM lifetime.
  """

  @persistent_key {__MODULE__, :info}

  @type t :: %{
          sha: String.t(),
          dirty: boolean(),
          ref: String.t() | nil,
          source: :release | :working_tree | :unknown
        }

  @doc """
  Returns memoized build information, falling back to `:unknown` on failure.
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
  Release step that writes the build facts where `release_file_path/0` reads
  them. Git failure is serialized as unknown facts instead of aborting the
  release.
  """
  @spec write_release_file(Mix.Release.t()) :: Mix.Release.t()
  def write_release_file(%Mix.Release{} = release) do
    facts =
      case git_facts() do
        {:ok, f} -> f
        :error -> %{sha: "unknown", dirty: false, ref: nil}
      end

    properties = Map.fetch!(release.applications, :lcars_fleet)
    vsn = Keyword.fetch!(properties, :vsn)
    # Keep this destination aligned with release_file_path/0.
    priv_dir = Path.join([release.path, "lib", "lcars_fleet-#{vsn}", "priv", "api"])

    File.mkdir_p!(priv_dir)
    File.write!(Path.join(priv_dir, "build_info.txt"), serialize(facts))

    release
  end

  @doc """
  Parses an embedded build-info file. Missing fields use unknown defaults;
  unreadable files return `:error`.
  """
  @spec read_release_file(Path.t()) :: {:ok, t()} | :error
  def read_release_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, _} -> :error
    end
  end

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
    Application.app_dir(:lcars_fleet, "priv/api/build_info.txt")
  end

  defp resolve_working_tree do
    case git_facts() do
      {:ok, facts} -> Map.put(facts, :source, :working_tree)
      :error -> unknown()
    end
  end

  # GIT FIRST, ENV SECOND — and the order is the point. A working tree has the truth and can also
  # tell whether it is dirty; an env var carries only what someone chose to pass. But a container
  # build stage has NO `.git` (deliberately: a worktree pointer is dead once the context is copied),
  # so git ALONE makes every image report `sha: "unknown"` — `fleet_v2 status` then says
  # "build unknown ref= (source=release)" on a box where the build is perfectly identified.
  #
  # The env fallback is NOT a second source of truth competing with the first: it is what the build
  # passes when the first is unavailable BY CONSTRUCTION. `dirty` stays false there, because a build
  # context carries no way to know — and claiming clean would be worse than saying nothing, so the
  # ref is left nil rather than invented.
  defp git_facts do
    case git(["rev-parse", "--short", "HEAD"]) do
      {:ok, sha} -> {:ok, %{sha: sha, dirty: dirty?(), ref: working_tree_ref()}}
      :error -> env_facts()
    end
  end

  @doc false
  # Expose pour le test : c'est le SEUL chemin par lequel une image obtient sa revision, et il n'a
  # pas de git pour le corroborer. Un repli non teste est un repli qu'on decouvre casse en lisant
  # « unknown » dans un banc, six semaines apres.
  @spec env_facts() :: {:ok, map()} | :error
  def env_facts do
    case System.get_env("LCARS_GIT_SHA") do
      nil -> :error
      "" -> :error
      "unknown" -> :error
      sha -> {:ok, %{sha: sha, dirty: false, ref: nil}}
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

  defp git(args) do
    case Fleet.Credentials.Shell.run("git", args, timeout_ms: 5_000) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp unknown, do: %{sha: "unknown", dirty: false, ref: nil, source: :unknown}

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
