defmodule Fleet.API.BuildInfo do
  @moduledoc """
  Reports SHA, dirty flag, ref and resolution source, memoized for the BEAM lifetime.
  Prefers any readable priv/api/build_info.txt, then Git, then LCARS_GIT_SHA.
  Unknown and environment-derived facts use dirty:false without proving a clean tree.
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
  Writes build facts into the release's priv/api/build_info.txt. Git failure falls
  back to LCARS_GIT_SHA or unknown facts; missing release metadata and file failures
  can raise. Returns the release unchanged after writing.
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

  # Git takes precedence over LCARS_GIT_SHA, supplied by image builds without .git.
  # The fallback does not validate the SHA and cannot measure dirty state or branch.
  defp git_facts do
    case git(["rev-parse", "--short", "HEAD"]) do
      {:ok, sha} -> {:ok, %{sha: sha, dirty: dirty?(), ref: working_tree_ref()}}
      :error -> env_facts()
    end
  end

  @doc false

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
