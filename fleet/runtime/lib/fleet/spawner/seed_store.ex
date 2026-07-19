defmodule Fleet.Spawner.SeedStore do
  @moduledoc """
  Pod seed-store. When a PROJECT-pod dies, the FIRST ROUND of its ACTIVE session JSONl
  (its memory) is checkpointed to `<seed_root>/<projet>/pods/<role>.jsonl` + a seed map
  `<role>.json` (`{uuid, slug}`) for later recall (`--resume`).
  A checkpoint failure NEVER kills the pod: every failure lands as a logged warning + `{:error, _}`
  (which the dying `Pod` discards) and the teardown proceeds. What is lost is only the
  session-memory bonus — the work's durable truth lives on the forge, not in the seed.

  - `seed_root`: `:fleet_spawner, :seed_store_root` (default `~/.lcars/seeds` =
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

  **Last revised**: 2026-07-19
  """
  require Logger

  @doc """
  Checkpoints the seed of a dying PROJECT-pod. `session_id` = the DETERMINISTIC BUILDER of the Desktop
  slot (the `session_id` pre-allocated at spawn): it is the `uuid` stored in the seed map, SINGLE SOURCE
  of the pod's identity — NOT the live jsonl's UUID (which a `/clear` may have rotated). The content
  (first round) and the `slug` come from the ACTIVE jsonl. With no live jsonl → `:none`.
  Never raises to the caller: an unconfined name is refused (logged warning + `{:error, _}`), any
  FS/JSON failure is rescued into a logged warning + `{:error, _}` — the teardown proceeds, only the
  session-memory bonus is lost (the work truth lives on the forge).
  """
  @spec checkpoint(Path.t(), String.t(), String.t(), String.t()) ::
          :ok | :none | {:error, term()}
  def checkpoint(pod_dir, projet, role, session_id)
      when is_binary(pod_dir) and is_binary(projet) and is_binary(role) and is_binary(session_id) do
    # `projet` AND `role` are path COMPONENTS of the seed-store (`<root>/<projet>/pods/<role>.jsonl`).
    # They come from `rc_name` (a dispatch/recall input, uncontrolled by construction): a `..`/`/`
    # would traverse outside the store (writing an arbitrary host `.jsonl`). We cast both into a slug and
    # confine the destination directory under the root BEFORE any `mkdir_p!`/`write!` — a malformed name
    # never reaches the FS (refusal = logged warning + `{:error, _}`; the checkpoint is a non-fatal
    # memory bonus, the dying pod proceeds).
    with {:ok, projet_slug} <- Fleet.Slug.cast(projet),
         {:ok, role_slug} <- Fleet.Slug.cast(role),
         {:ok, projet_dir} <- Fleet.Slug.confined_join(root(), projet_slug) do
      do_checkpoint(pod_dir, projet_slug, role_slug, session_id, Path.join(projet_dir, "pods"))
    else
      {:error, reason} ->
        Logger.warning(
          "SeedStore: checkpoint refused (unconfined name) projet=#{inspect(projet)} role=#{inspect(role)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    # The "never raises to the caller" contract must cover `root()` too: the default root derives
    # from `Fleet.Layout.state_dir/0`, which raises on an unresolvable HOME. A raise here must not
    # kill the dying pod — same downgrade as `do_checkpoint` (logged warning + `{:error, _}`).
    e ->
      Logger.warning(
        "SeedStore: checkpoint #{inspect(projet)}/#{inspect(role)} FAILED (non-fatal): #{inspect(e)}"
      )

      {:error, e}
  end

  defp do_checkpoint(pod_dir, projet, role, session_id, dest_dir) do
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
        File.mkdir_p!(dest_dir)

        # We keep ONLY the FIRST ROUND (minimal resumable seed = the pod's initial setup/brief),
        # NOT the whole session — the work re-derives from the forge (single-source axiom).
        # This subset `--resume`s correctly with only the round-1 context.
        File.write!(Path.join(dest_dir, "#{role}.jsonl"), first_round(jsonl))

        File.write!(
          Path.join(dest_dir, "#{role}.json"),
          Jason.encode!(%{"uuid" => uuid, "slug" => slug, "projet" => projet, "role" => role})
        )

        Logger.info(
          "SeedStore: checkpoint #{projet}/#{role} (uuid=#{uuid} = deterministic builder) → #{dest_dir}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("SeedStore: checkpoint #{projet}/#{role} FAILED (non-fatal): #{inspect(e)}")
      {:error, e}
  end

  # First round = the lines up to and INCLUDING the 1st `assistant` event (brief/setup + 1st reply).
  # This is the minimal resumable seed; the rest of the session is dropped (forge re-derivable).
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

  @doc """
  Reads the seed map of a checkpointed seed. `{:ok, %{uuid, slug, jsonl}}` (jsonl = the seed's path in the
  store) if the seed map AND the JSONl exist; otherwise `:none`.
  """
  @spec read_map(String.t(), String.t()) :: {:ok, map()} | :none
  def read_map(projet, role) when is_binary(projet) and is_binary(role) do
    # Leaf-read of the seed-store: `projet`/`role` are path components. Same casts as
    # `checkpoint/4` (an exposed `recall(projet, role)` takes these two args from a caller) → an
    # unconfined name yields `:none` (seed not found) rather than reading an arbitrary host `.json`/`.jsonl`.
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
  Restores a seed into the HOME of a recall pod: `cp`s the JSONl to
  `<pod_dir>/.claude/projects/<slugify(cwd)>/<uuid>.jsonl`. The `cwd` is that of the recall pod
  (slug recomputed) → `--resume <uuid>` (cwd = `cwd`) finds the session again. Returns `{:ok, dest}`.
  """
  @spec restore(Path.t(), Path.t(), Path.t(), String.t()) :: {:ok, Path.t()}
  def restore(seed_jsonl, pod_dir, cwd, uuid)
      when is_binary(seed_jsonl) and is_binary(pod_dir) and is_binary(cwd) and is_binary(uuid) do
    # `cwd` is already confined by `slugify` (everything outside `[A-Za-z0-9-]` → `-`, so neither `/` nor `..`). The
    # `uuid`, on the other hand, comes from the seed's `.json` (`read_map`): if that file carried a hostile `uuid`
    # (`../../x`), it would interpolate into the LEAF and write outside the `projects/<slug>/` directory. So we
    # confine the resolved `dest` under the pod_dir BEFORE the `cp!` — fail-loud (raise) on escape. The
    # caller `maybe_recall_restore` RESCUES this raise into `{:error, {:recall_restore_failed, _}}` → the
    # `:projecting` `with` routes it to `transition_failed` (clean tombstone), the pod does not launch.
    dir = Path.join([pod_dir, ".claude", "projects", slugify(cwd)])
    File.mkdir_p!(dir)
    dest = Path.expand(Path.join(dir, "#{uuid}.jsonl"))

    unless Fleet.Slug.under_root?(dest, pod_dir) do
      raise ArgumentError,
            "SeedStore.restore: unconfined uuid (#{inspect(uuid)}) — escape refused"
    end

    File.cp!(seed_jsonl, dest)
    # Desktop-slot preservation: after the seed BODY lands, graft the captured `bridge_status`
    # line (if any) so `--resume` RE-ATTACHES the same server slot instead of minting a new one
    # (proven 2026-07-19, F1/F5: same uuid + own bridge_status → reattach; without it → new slot,
    # the "12 archs" bug). Keyed by the deterministic `uuid` = the slot's identity. Best-effort:
    # a missing/failed sidecar just means this boot re-mints + re-captures (self-healing).
    maybe_inject_slot_bridge(dest, uuid)
    {:ok, dest}
  end

  @doc """
  Claude slug of a `cwd`: every character outside `[A-Za-z0-9-]` → `-` (NO collapsing of `-`).
  E.g. `/home/x/pod_a-b` → `-home-x-pod-a-b`.

  VENDOR COMPAT — reproduces BIT FOR BIT Claude Code's slugification algo (proven against v2.1.183, cf.
  seed_store_test). This is what lets us find `~/.claude/projects/<slug>/<uuid>.jsonl` again at resume.
  Do NOT replace with `Fleet.Slug` nor `PodId.component` (different charsets): a slug that does not match
  Claude's points at the wrong directory -> resume breaks. Domain frozen by an external system.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(path), do: String.replace(path, ~r/[^A-Za-z0-9-]/, "-")

  # ── Desktop-slot preservation (per-identity RC-identity sidecar) ─────────────
  # A Desktop remote-control slot is bound server-side to the LOCAL session that minted it. It
  # re-attaches ONLY via `--resume` on a jsonl carrying its RC-identity record(s) (proven live
  # 2026-07-19; a create or a resume-without-them mints a NEW slot → the "12 archs" bug). So we
  # capture the RC-identity line(s) at boot (once registered) into a per-identity sidecar, and graft
  # them back onto the restored seed at the next boot. Keyed by the DETERMINISTIC uuid (the slot's
  # identity); per-human via `seed_root`. Universal (arch/judge/eng), gated caller-side on
  # `remote_control?` (a no-RC pod never registers → nothing to capture).
  #
  # ⚠ TWO record formats, both seen live (2026-07-19): `bridge-session` (`bridgeSessionId` = the
  # slot; emitted by a RESUMED session — e.g. the arch, manual-mode) AND/OR `system`+`bridge_status`
  # (`url` = session_01…; emitted by a FRESH `--remote-control` session). A session emits one or
  # both — we preserve WHATEVER is present. Injecting the `bridge-session` line was proven to
  # re-attach the arch's `cse_…` slot (control: no sidecar → a NEW random cse_ each boot).

  @doc """
  Captures the pod's CURRENT Desktop slot into `<seed_root>/_slots/<uuid>.jsonl`, so the next boot
  re-attaches it. Reads the live jsonl (`SessionFiles.latest_jsonl`, robust to `/clear`) and stores
  the most recent RC-identity record(s) — `bridge-session` and/or `system/bridge_status` — written
  by claude at `--remote-control` registration.
  `:ok` (captured) · `:none` (no jsonl / not registered yet → caller retries) · `{:error, _}`.
  Best-effort: never raises to the caller (a miss = the slot is re-minted + re-captured next boot).
  """
  @spec capture_slot_bridge(Path.t(), String.t()) :: :ok | :none | {:error, term()}
  def capture_slot_bridge(pod_dir, uuid) when is_binary(pod_dir) and is_binary(uuid) do
    with {:ok, uuid} <- Fleet.Spawner.SessionId.cast(uuid),
         {:ok, jsonl} <- Fleet.Spawner.Pod.SessionFiles.latest_jsonl(pod_dir),
         [_ | _] = lines <- rc_identity_lines(jsonl) do
      File.mkdir_p!(slot_dir())
      File.write!(slot_path(uuid), Enum.join(lines, "\n") <> "\n")
      :ok
    else
      :none -> :none
      [] -> :none
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  # Grafts the captured RC-identity line(s) (if the per-identity sidecar exists) onto a freshly-
  # restored seed → `--resume` re-attaches the SAME server slot. Idempotent (skips if the dest
  # already carries an RC-identity record; the base seed never does). Best-effort: any failure is
  # swallowed (the restore already succeeded; slot preservation is a bonus).
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

  # Most recent RC-identity record of EACH format present (`bridge-session` / `system/bridge_status`),
  # as raw lines. Empty list = the session has not registered RC yet.
  defp rc_identity_lines(jsonl_path) do
    jsonl_path
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "bridge-session"}} -> Map.put(acc, :session, String.trim_trailing(line))
        {:ok, %{"type" => "system", "subtype" => "bridge_status"}} -> Map.put(acc, :status, String.trim_trailing(line))
        _ -> acc
      end
    end)
    |> Map.values()
  end

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

  # Default = per-human state (`~/.lcars/seeds`), the same value `runtime.exs` re-derives for the
  # `LCARS_SEED_STORE_ROOT` env override. `Fleet.Layout.state_dir/0` raises on an unresolvable
  # HOME: the no-raise path (`checkpoint/4`) rescues it; `read_map/2` (recall, a deliberate API
  # call) inherits Layout's fail-loud doctrine.
  defp root,
    do:
      Application.get_env(
        :fleet_spawner,
        :seed_store_root,
        Path.join(Fleet.Layout.state_dir(), "seeds")
      )
end
