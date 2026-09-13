defmodule Fleet.Spawner.SeedStore do
  @moduledoc """
  Stores first-round session seeds for recall and per-identity Desktop bridge sidecars.
  Checkpoints use `<seed_root>/<project>/pods/<role>[-<issue>].jsonl` plus a JSON descriptor.
  The issue suffix prevents concurrent tickets from overwriting each other's memory.

  The descriptor UUID is the builder identity supplied at spawn. Content and recorded cwd slug
  come from the newest session JSONL by mtime: `/clear` may rotate its UUID without changing the
  builder. Restore uses the current cwd's slug and the supplied UUID.

  Checkpoint failures are non-fatal to teardown; durable work remains on the forge. No Git
  operation runs here. The root is `:lcars_fleet, :spawner_seed_store_root`, defaulting to
  `Fleet.Layout.state_dir()/seeds`; `runtime.exs` supports `LCARS_SEED_STORE_ROOT`.
  """
  require Logger

  alias Fleet.Slug
  alias Fleet.Spawner.SessionId

  # Bound scan work in the pod callback before teardown; reaching the budget can yield a partial seed.
  @scan_max_bytes 8_000_000
  @scan_max_lines 50_000

  # File.stream! materializes each line before this byte check; one huge line can still use memory.
  defp bounded_lines(jsonl_path) do
    jsonl_path
    |> File.stream!()
    |> Stream.transform(0, fn line, bytes ->
      next = bytes + byte_size(line)
      if next > @scan_max_bytes, do: {:halt, bytes}, else: {[line], next}
    end)
    |> Stream.take(@scan_max_lines)
  end

  @doc """
  Stores the newest transcript through its first assistant event, within the scan budget,
  under the supplied builder `session_id`. No transcript returns `:none` without writing.
  Invalid path components and filesystem/JSON failures return a logged `{:error, _}`.
  """
  @spec checkpoint(Path.t(), String.t(), String.t(), String.t(), pos_integer() | nil) ::
          :ok | :none | {:error, term()}
  def checkpoint(pod_dir, project, role, session_id, issue)
      when is_binary(pod_dir) and is_binary(project) and is_binary(role) and
             is_binary(session_id) and (is_nil(issue) or is_integer(issue)) do
    # Validate caller-supplied path components before creating or writing the seed directory.
    with {:ok, project_slug} <- Slug.cast(project),
         {:ok, role_slug} <- Slug.cast(role),
         {:ok, project_dir} <- Slug.confined_join(root(), project_slug) do
      do_checkpoint(
        pod_dir,
        project_slug,
        role_slug,
        session_id,
        Path.join(project_dir, "pods"),
        issue
      )
    else
      {:error, reason} ->
        Logger.warning(
          "SeedStore: checkpoint refused (unconfined name) project=#{inspect(project)} role=#{inspect(role)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning(
        "SeedStore: checkpoint #{inspect(project)}/#{inspect(role)} FAILED (non-fatal): #{inspect(e)}"
      )

      {:error, e}
  end

  defp seed_basename(role, nil), do: role
  defp seed_basename(role, issue) when is_integer(issue), do: "#{role}-#{issue}"

  defp do_checkpoint(pod_dir, project, role, session_id, dest_dir, issue) do
    case Fleet.Spawner.Pod.SessionFiles.latest_jsonl(pod_dir) do
      :none ->
        :none

      # An unreadable sessions directory is a capture failure, not an empty session.
      {:error, reason} = err ->
        Logger.error(
          "SeedStore: checkpoint #{project}/#{role} — sessions directory unreadable " <>
            "(#{inspect(reason)}), NOTHING captured. This is not an empty pod: the seed of this " <>
            "run is lost and a recall will start cold."
        )

        err

      {:ok, jsonl} ->
        uuid = session_id
        slug = Path.basename(Path.dirname(jsonl))
        base = seed_basename(role, issue)
        File.mkdir_p!(dest_dir)

        # Retain setup/brief context; subsequent work is reconstructed from the forge.
        content = first_round(jsonl)

        # Recheck after reading: the pod can replace its writable transcript with a host-file link.
        # This catches links still present here, not a swap-and-restore race during the read.
        # A captured host file would otherwise become a seed delivered to a later pod.
        unless Slug.link_free_under?(jsonl, pod_dir) do
          raise ArgumentError,
                "SeedStore.checkpoint: #{inspect(jsonl)} became a symlink while being read — " <>
                  "capture DROPPED (a pod that swaps its own transcript for a host file is " <>
                  "reaching through the daemon, which runs outside its sandbox)"
        end

        File.write!(Path.join(dest_dir, "#{base}.jsonl"), content)

        # read_map/3 consumes uuid and slug; the remaining fields aid manual inspection.
        File.write!(
          Path.join(dest_dir, "#{base}.json"),
          Jason.encode!(%{
            "uuid" => uuid,
            "slug" => slug,
            "project" => project,
            "role" => role,
            "issue" => issue
          })
        )

        Logger.info(
          "SeedStore: checkpoint #{project}/#{base} (uuid=#{uuid} = deterministic builder) → #{dest_dir}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("SeedStore: checkpoint #{project}/#{role} FAILED (non-fatal): #{inspect(e)}")
      {:error, e}
  end

  defp first_round(jsonl_path) do
    jsonl_path
    |> bounded_lines()
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

  @doc """
  Reads the seed map of a checkpointed seed. `{:ok, %{uuid, slug, jsonl}}` (jsonl = the seed's path in the
  store) if the seed map AND the JSONl exist; otherwise `:none`.
  """
  @spec read_map(String.t(), String.t(), pos_integer() | nil) :: {:ok, map()} | :none
  def read_map(project, role, issue)
      when is_binary(project) and is_binary(role) and (is_nil(issue) or is_integer(issue)) do
    with {:ok, project_slug} <- Slug.cast(project),
         {:ok, role_slug} <- Slug.cast(role),
         {:ok, project_dir} <- Slug.confined_join(root(), project_slug),
         dir = Path.join(project_dir, "pods"),
         base = seed_basename(role_slug, issue),
         jsonl = Path.join(dir, "#{base}.jsonl"),
         {:ok, raw} <- File.read(Path.join(dir, "#{base}.json")),
         {:ok, %{"uuid" => uuid} = m} <- Jason.decode(raw),
         true <- File.exists?(jsonl) do
      {:ok, %{uuid: uuid, slug: m["slug"], jsonl: jsonl}}
    else
      _ -> :none
    end
  end

  @doc """
  Restores a seed to `<pod_dir>/.claude/projects/<slugify(cwd)>/<uuid>.jsonl`.

  Checks lexical confinement and symlinks before copying; these checks are not atomic with writes.
  Returns `{:ok, dest}`; path and filesystem failures raise.
  """
  @spec restore(Path.t(), Path.t(), Path.t(), String.t()) :: {:ok, Path.t()}
  def restore(seed_jsonl, pod_dir, cwd, uuid)
      when is_binary(seed_jsonl) and is_binary(pod_dir) and is_binary(cwd) and is_binary(uuid) do
    dir = Path.join([pod_dir, ".claude", "projects", slugify(cwd)])
    dest = Path.expand(Path.join(dir, "#{uuid}.jsonl"))

    unless Slug.under_root?(dest, pod_dir) do
      raise ArgumentError,
            "SeedStore.restore: unconfined uuid (#{inspect(uuid)}) — escape refused"
    end

    # Lexical confinement misses symlinks in the pod-owned tree. Check before mkdir_p!,
    # which could otherwise follow a link and create directories outside the sandbox.
    unless Slug.link_free_under?(dest, pod_dir) do
      raise ArgumentError,
            "SeedStore.restore: a symlink stands between #{inspect(pod_dir)} and " <>
              "#{inspect(dest)} — restore REFUSED. The pod owns its tree; it does not get to " <>
              "choose where the daemon writes."
    end

    File.mkdir_p!(dir)

    File.cp!(seed_jsonl, dest)
    # Shared base seeds may carry another human's capture-time sessionId.
    normalize_session_id!(dest, uuid)
    maybe_inject_slot_bridge(dest, uuid)
    {:ok, dest}
  end

  @doc """
  Reproduces Claude Code v2.1.183 cwd slugification byte-for-byte: every character outside
  `[A-Za-z0-9-]` becomes `-`, without collapse. This is vendor compatibility, not `Fleet.Slug`.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(path), do: String.replace(path, ~r/[^A-Za-z0-9-]/, "-")

  @doc """
  Captures the current Desktop slot as a resumable per-identity sidecar.

  The F5 seed contains the latest `mode`, `permission-mode`, `bridge-session` and
  `system/bridge_status` records, merged by type with the previous sidecar so resumed sessions
  cannot thin it. Both RC identity formats are observed live and either may be
  emitted; capture starts only after at least one is present.

  `:ok` (captured) · `:none` (no jsonl / not registered yet → caller retries) · `{:error, _}`.
  Capture is best-effort and never raises to the caller.
  """
  @spec capture_slot_bridge(Path.t(), String.t()) :: :ok | :none | {:error, term()}
  def capture_slot_bridge(pod_dir, uuid) when is_binary(pod_dir) and is_binary(uuid) do
    with {:ok, uuid} <- SessionId.cast(uuid),
         {:ok, jsonl} <- Fleet.Spawner.Pod.SessionFiles.latest_jsonl(pod_dir),
         %{} = live <- seed_records(jsonl),
         true <- rc_registered?(live) || :none do
      File.mkdir_p!(slot_dir())
      merged = Map.merge(existing_seed_records(slot_path(uuid)), live)
      File.write!(slot_path(uuid), (merged |> Map.values() |> Enum.join("\n")) <> "\n")
      :ok
    else
      :none -> :none
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns the non-empty slot seed for a valid v4 UUID, or `:none`.
  """
  @spec slot_seed(String.t()) :: {:ok, Path.t()} | :none
  def slot_seed(uuid) when is_binary(uuid) do
    with {:ok, uuid} <- SessionId.cast(uuid),
         path = slot_path(uuid),
         {:ok, %{size: size}} when size > 0 <- File.stat(path) do
      {:ok, path}
    else
      _ -> :none
    end
  end

  # Slot preservation is best-effort after the seed body has already been restored.
  defp maybe_inject_slot_bridge(dest, uuid) do
    with {:ok, uuid} <- SessionId.cast(uuid),
         sidecar = slot_path(uuid),
         true <- File.exists?(sidecar),
         {:ok, raw} <- File.read(sidecar),
         body = String.trim_trailing(raw),
         true <- body != "",
         false <- dest_has_rc_identity?(dest) do
      File.write!(dest, body <> "\n", [:append])
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Most recent F5 record of each type; both RC formats are observed live.
  defp seed_records(jsonl_path) do
    jsonl_path
    |> bounded_lines()
    |> Enum.reduce(%{}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "mode"}} ->
          Map.put(acc, :mode, String.trim_trailing(line))

        {:ok, %{"type" => "permission-mode"}} ->
          Map.put(acc, :permission, String.trim_trailing(line))

        {:ok, %{"type" => "bridge-session"}} ->
          Map.put(acc, :session, String.trim_trailing(line))

        {:ok, %{"type" => "system", "subtype" => "bridge_status"}} ->
          Map.put(acc, :status, String.trim_trailing(line))

        _ ->
          acc
      end
    end)
  end

  # Missing means no previous records. Read errors must raise before capture overwrites the
  # sidecar, preserving its previous contents. Malformed JSON lines are ignored by seed_records/1.
  defp existing_seed_records(path) do
    if File.exists?(path) do
      seed_records(path)
    else
      %{}
    end
  end

  defp rc_registered?(records),
    do: Map.has_key?(records, :session) or Map.has_key?(records, :status)

  defp dest_has_rc_identity?(dest) do
    case File.read(dest) do
      {:ok, c} ->
        String.contains?(c, ~s("subtype":"bridge_status")) or
          String.contains?(c, ~s("type":"bridge-session"))

      _ ->
        false
    end
  end

  defp slot_dir, do: Path.join(root(), "_slots")
  defp slot_path(uuid), do: Path.join(slot_dir(), "#{uuid}.jsonl")

  # Only sessionId is normalized; uuid, parentUuid and bridgeSessionId have distinct meanings.
  defp normalize_session_id!(path, uuid) do
    content = File.read!(path)
    File.write!(path, Regex.replace(~r/"sessionId":"[^"]*"/, content, ~s("sessionId":"#{uuid}")))
  end

  # get_env/3 would eagerly evaluate Layout.state_dir() and could raise for an unresolvable HOME
  # even when the configured override is intended to avoid that dependency.
  defp root do
    case Application.fetch_env(:lcars_fleet, :spawner_seed_store_root) do
      {:ok, path} -> path
      :error -> Path.join(Fleet.Layout.state_dir(), "seeds")
    end
  end
end
