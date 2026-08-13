defmodule Fleet.Spawner.SeedStore do
  @moduledoc """
  Pod seed-store. When a PROJECT-pod dies, the FIRST ROUND of its ACTIVE session JSONl
  (its memory) is checkpointed to `<seed_root>/<project>/pods/<role>.jsonl` + a seed map
  `<role>.json` (`{uuid, slug}`) for later recall (`--resume`).
  A checkpoint failure NEVER kills the pod: every failure lands as a logged warning + `{:error, _}`
  (which the dying `Pod` discards) and the teardown proceeds. What is lost is only the
  session-memory bonus — the work's durable truth lives on the forge, not in the seed.

  - `seed_root`: `:lcars_fleet, :spawner_seed_store_root` (default `~/.lcars/seeds` =
    `Fleet.Layout.state_dir()/seeds`; operator override `LCARS_SEED_STORE_ROOT`, cf. `runtime.exs`).
  - The seed map's `uuid` = the DETERMINISTIC BUILDER of the Desktop slot (the `session_id`
    pre-allocated at spawn, passed as an argument): it is the SINGLE SOURCE of the pod's identity. It is
    NOT derived from the live jsonl's UUID — a `/clear` rotates the live UUID, and a seed that followed it
    would make the pod resume a bastard slot (≠ builder) at recall.
  - The CONTENT and the `slug`, on the other hand, come from the ACTIVE jsonl = the most recently modified
    under `<pod_dir>/.claude/projects/*/` (the LIVE session, robust to `/clear` rotation). With no live
    jsonl (`:none`), there is no content to checkpoint → nothing is written.
  - The seed map `<role>.json` therefore carries the `uuid` (= builder) + the `slug` (cwd-slug of the live jsonl):
    recall restores the JSONl to `projects/<slug>/<uuid>.jsonl` then `--resume <uuid>`.

  NB git: the `cp` drops the seed; putting the work repo under git is a SEPARATE gesture (outside the
  teardown hot-path — no `git` in a pod's death).
  """
  require Logger

  # Budget for the JSONL scans (`first_round/1`, `seed_records/1`): these run in the pod's
  # GenStatem callback during CAPTURE and BEFORE teardown — an enormous, malformed or
  # marker-less file (a runaway agent, a corrupt transcript) would hold the mailbox, delay
  # the kill and grow memory without a bound. The seed we actually need lives in the first
  # rounds; past the budget the scan STOPS best-effort (a partial seed still resumes; a
  # missing marker degrades to no-seed, never a hang). Bytes cap first (a single pathological
  # line), lines cap second.
  @scan_max_bytes 8_000_000
  @scan_max_lines 50_000

  # Lazy line stream bounded by BOTH a byte budget and a line budget: whichever trips first
  # halts the scan. `File.stream!` is already lazy (one line at a time); this only caps how
  # far it walks, so a 2 GB transcript never fully loads.
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
  Checkpoints the seed of a dying PROJECT-pod. `session_id` = the DETERMINISTIC BUILDER of the Desktop
  slot (the `session_id` pre-allocated at spawn): it is the `uuid` stored in the seed map, SINGLE SOURCE
  of the pod's identity — NOT the live jsonl's UUID (which a `/clear` may have rotated). The content
  (first round) and the `slug` come from the ACTIVE jsonl. With no live jsonl → `:none`.
  Never raises to the caller: an unconfined name is refused (logged warning + `{:error, _}`), any
  FS/JSON failure is rescued into a logged warning + `{:error, _}` — the teardown proceeds, only the
  session-memory bonus is lost (the work truth lives on the forge).
  """
  @spec checkpoint(Path.t(), String.t(), String.t(), String.t(), pos_integer() | nil) ::
          :ok | :none | {:error, term()}
  def checkpoint(pod_dir, project, role, session_id, issue)
      when is_binary(pod_dir) and is_binary(project) and is_binary(role) and
             is_binary(session_id) and (is_nil(issue) or is_integer(issue)) do
    # `project` AND `role` are path COMPONENTS of the seed-store. They come from `rc_name` (a
    # dispatch/recall input, uncontrolled by construction): a `..`/`/` would traverse outside the
    # store (writing an arbitrary host `.jsonl`). We cast both into a slug and confine the
    # destination directory under the root BEFORE any `mkdir_p!`/`write!` — a malformed name never
    # reaches the FS (refusal = logged warning + `{:error, _}`; the checkpoint is a non-fatal
    # memory bonus, the dying pod proceeds).
    with {:ok, project_slug} <- Fleet.Slug.cast(project),
         {:ok, role_slug} <- Fleet.Slug.cast(role),
         {:ok, project_dir} <- Fleet.Slug.confined_join(root(), project_slug) do
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

  # The seed's basename. `<role>` for a pod keyed on its PROJECT (one per repo by construction,
  # so the role alone identifies it); `<role>-<issue>` for a pod keyed on its TICKET.
  #
  # Before this discriminator, every producer of a project wrote `<role>.jsonl`: the day producers
  # became ticket-scoped, the engineers of tickets 41 and 42 checkpointed to the SAME file and the
  # last to die won. A `recall` then resumed whichever session happened to end last — another
  # ticket's conversation, silently, on a rail whose whole purpose is to restore the right memory.
  # Same class as the pool nibble: a key that was faithful under "one producer per repo" and became
  # a lie the moment that assumption was removed.
  defp seed_basename(role, nil), do: role
  defp seed_basename(role, issue) when is_integer(issue), do: "#{role}-#{issue}"

  defp do_checkpoint(pod_dir, project, role, session_id, dest_dir, issue) do
    # Active JSONl = the most recent under .claude/projects/*/*.jsonl (shared authority of the glob:
    # `Pod.SessionFiles.latest_jsonl/1`, robust to volatile files).
    case Fleet.Spawner.Pod.SessionFiles.latest_jsonl(pod_dir) do
      :none ->
        :none

      {:ok, jsonl} ->
        # The stored uuid = the DETERMINISTIC BUILDER (`session_id` pre-allocated at spawn), the SINGLE
        # source of the Desktop slot's identity. We do NOT derive it from `Path.basename(jsonl)`: a `/clear`
        # rotates the live jsonl's UUID, and a seed that followed it would resume a bastard slot
        # (≠ builder) at recall. Only the `slug` (cwd-slug) and the CONTENT come from the live jsonl.
        uuid = session_id
        slug = Path.basename(Path.dirname(jsonl))
        base = seed_basename(role, issue)
        File.mkdir_p!(dest_dir)

        # We keep ONLY the FIRST ROUND (minimal resumable seed = the pod's initial setup/brief),
        # NOT the whole session — the work re-derives from the forge (single-source axiom).
        # This subset `--resume`s correctly with only the round-1 context.
        File.write!(Path.join(dest_dir, "#{base}.jsonl"), first_round(jsonl))

        # Sidecar descriptor. `read_map/3` reads ONLY `uuid` and `slug`; the rest is there for a
        # human opening the seed store by hand. Nothing parses them, which is why adding `issue`
        # cannot break a seed already on disk — an old file keeps resuming, the extra key is
        # simply never looked at.
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

  # Minimal resumable context: input through the first assistant event, inclusive.
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
    # Leaf-read of the seed-store: `project`/`role` are path components. Same casts as
    # `checkpoint/5` (an exposed `recall/3` takes these args from a caller) → an unconfined name
    # yields `:none` (seed not found) rather than reading an arbitrary host `.json`/`.jsonl`.
    with {:ok, project_slug} <- Fleet.Slug.cast(project),
         {:ok, role_slug} <- Fleet.Slug.cast(role),
         {:ok, project_dir} <- Fleet.Slug.confined_join(root(), project_slug),
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

  The destination is confined under the pod directory before copying. Returns `{:ok, dest}`.
  """
  @spec restore(Path.t(), Path.t(), Path.t(), String.t()) :: {:ok, Path.t()}
  def restore(seed_jsonl, pod_dir, cwd, uuid)
      when is_binary(seed_jsonl) and is_binary(pod_dir) and is_binary(cwd) and is_binary(uuid) do
    dir = Path.join([pod_dir, ".claude", "projects", slugify(cwd)])
    File.mkdir_p!(dir)
    dest = Path.expand(Path.join(dir, "#{uuid}.jsonl"))

    unless Fleet.Slug.under_root?(dest, pod_dir) do
      raise ArgumentError,
            "SeedStore.restore: unconfined uuid (#{inspect(uuid)}) — escape refused"
    end

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
  cannot thin it. Both RC identity formats were observed live on 2026-07-19 and either may be
  emitted; capture starts only after at least one is present.

  `:ok` (captured) · `:none` (no jsonl / not registered yet → caller retries) · `{:error, _}`.
  Capture is best-effort and never raises to the caller.
  """
  @spec capture_slot_bridge(Path.t(), String.t()) :: :ok | :none | {:error, term()}
  def capture_slot_bridge(pod_dir, uuid) when is_binary(pod_dir) and is_binary(uuid) do
    with {:ok, uuid} <- Fleet.Spawner.SessionId.cast(uuid),
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
  Returns the non-empty slot seed for a deterministic UUID, or `:none`.
  """
  @spec slot_seed(String.t()) :: {:ok, Path.t()} | :none
  def slot_seed(uuid) when is_binary(uuid) do
    with {:ok, uuid} <- Fleet.Spawner.SessionId.cast(uuid),
         path = slot_path(uuid),
         {:ok, %{size: size}} when size > 0 <- File.stat(path) do
      {:ok, path}
    else
      _ -> :none
    end
  end

  # Slot preservation is best-effort after the seed body has already been restored.
  defp maybe_inject_slot_bridge(dest, uuid) do
    with {:ok, uuid} <- Fleet.Spawner.SessionId.cast(uuid),
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

  # Most recent F5 record of each type; both RC formats were observed live on 2026-07-19.
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

  defp existing_seed_records(path) do
    if File.exists?(path), do: seed_records(path), else: %{}
  rescue
    _ -> %{}
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

  # THE one definition of the seed root. `config/runtime.exs` posts the key only when the operator
  # set `LCARS_SEED_STORE_ROOT`; absent that, this is the answer, and there is no second one.
  #
  # `fetch_env/2`, never `get_env/3`: the third argument of `get_env/3` is an ordinary function
  # argument, evaluated on EVERY call even when the key is set. `Layout.state_dir()` raises on an
  # unresolvable HOME, so the eager form paid that raise on every `root()` — including in the
  # deployments that configure the key precisely to avoid depending on the home.
  defp root do
    case Application.fetch_env(:lcars_fleet, :spawner_seed_store_root) do
      {:ok, path} -> path
      :error -> Path.join(Fleet.Layout.state_dir(), "seeds")
    end
  end
end
