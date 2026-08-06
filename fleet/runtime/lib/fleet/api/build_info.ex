defmodule Fleet.API.BuildInfo do
  @moduledoc """
  Version of the served build — **observable, not deduced**.

  Which commit is running? This datum must be readable without inspecting the
  repo (a release is self-contained: bundled ERTS, embedded priv, **no git
  repo nor Mix at runtime**). `current/0` returns the short git SHA + a
  `dirty` flag + the `ref`, and a `:source` field that says **where the info
  comes from** — not a hidden fallback, an explicit and honest provenance.

  ## One source depending on context (`:source` makes it explicit)

    1. `:release` — the `priv/build_info.txt` file exists: it was embedded at
       `mix release` (cf. `write_release_file/1`, captured on the build machine
       where git exists). We read it, period. The release never touches git.
    2. `:working_tree` — no embedded file (source/dev mode): we query git LIVE
       (`rev-parse --short HEAD`, `--abbrev-ref HEAD`, `status --porcelain`) in
       the BEAM's cwd (the repo).
    3. `:unknown` — neither file, nor usable git (git absent, not a repo,
       release sandbox without priv): `%{sha: "unknown", dirty: false, ref: nil}`.

  ## Total / fail-safe

  This is an **observability** tool: it must NEVER raise nor prevent the fleet
  from booting. `System.cmd("git", …)` can raise (git absent →
  `ErlangError :enoent`) or exit in error (not a repo); every failure path
  falls back to `:unknown`. `current/0` is total by construction.

  ## Cache

  `current/0` is called at boot (log) AND potentially per request (endpoint
  `/api/version`). The result is memoized in `:persistent_term` (key
  `{__MODULE__, :info}`) on the 1st call — we don't spawn a `git` per request.
  In `:working_tree`/dev mode the SHA can change between two boots (recompile
  restarts the BEAM → 1st call recomputes): acceptable, the cache is
  deliberately NOT hot-invalidatable (the need doesn't exist).

  Module of **data + pure functions**: no process (no runtime state carried,
  no concurrency, no fault isolation). `:persistent_term` is a table cache,
  not a process.
  """

  @persistent_key {__MODULE__, :info}

  @type t :: %{
          sha: String.t(),
          dirty: boolean(),
          ref: String.t() | nil,
          source: :release | :working_tree | :unknown
        }

  @doc """
  Version of the served build, memoized. Total: never raises, falls back to
  `:unknown` on any failure.
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
  `mix release` step: captures the SHA on the build machine (git present)
  and writes `priv/build_info.txt` INTO the assembled release, before the `:tar`.

  The destination path is computed exactly as Mix copies the app
  (`<release.path>/lib/<app>-<vsn>/priv`, cf. `Mix.Release` `copy_app`) — not
  a hand-rolled glob. The runtime will re-read this file via
  `Application.app_dir(:lcars_fleet, "priv/api/build_info.txt")` → `source: :release`.

  If git fails at build, we write `unknown` facts rather than breaking the
  release build: the degradation is carried IN the artifact itself (the API
  then serves `sha: "unknown"`), not hidden.
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
    # `priv/api` (not `priv/`): MUST land exactly where `release_file_path/0` re-reads it —
    # `app_dir(:lcars_fleet, "priv/api/build_info.txt")` = `lib/lcars_fleet-<vsn>/priv/api/` in the release.
    priv_dir = Path.join([release.path, "lib", "lcars_fleet-#{vsn}", "priv", "api"])

    File.mkdir_p!(priv_dir)
    File.write!(Path.join(priv_dir, "build_info.txt"), serialize(facts))

    release
  end

  @doc """
  Reads + parses a `build_info.txt` file (the testable seam of the `:release`
  path). `{:ok, info}` if the file exists and is readable; `:error`
  otherwise (→ `current/0` switches to `working_tree`). The parse is total:
  absent field ⇒ default (`sha: "unknown"`, `dirty: false`, `ref: nil`).
  """
  @spec read_release_file(Path.t()) :: {:ok, t()} | :error
  def read_release_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse(content)}
      {:error, _} -> :error
    end
  end

  # --- internal resolution --------------------------------------------------

  # Final totality backstop: any unforeseen raise/throw → :unknown (the
  # cache will memoize this :unknown, we don't re-try git on every request).
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

  # Raw git facts (sha/dirty/ref) shared by the build (write_release_file)
  # and the runtime (resolve_working_tree). `:error` if HEAD is unreachable
  # (git absent / not a repo).
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

  # Total wrapper around git, BOUNDED (Shell authority): this runs on the boot path
  # (post_boot build-info trace) — an unbounded git on a hung FS would hold the boot
  # completion. Every failure (non-zero, absent binary, timeout) reads :error.
  defp git(args) do
    case Fleet.Credentials.Shell.run("git", args, timeout_ms: 5_000) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp unknown, do: %{sha: "unknown", dirty: false, ref: nil, source: :unknown}

  # --- (de)serialization of the embedded file -------------------------------
  # `key=value` format, one per line — readable by eye (and by the bash case
  # `fleet_v2 version`), trivial to parse, total.

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
