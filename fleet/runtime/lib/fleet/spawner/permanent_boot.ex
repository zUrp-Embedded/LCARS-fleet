defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Boot of the fleet-level Type 1 permanent pods **at startup of the fleet_v2
  runtime launched by the human** (`bin/fleet_v2 start` starts the BEAM under
  the human's UID then boots the permanent architect pod — human-launches
  model, no more system service, systemd removed). `fleet_spawner` extension
  (NOT a refactor).


  ## CRITICAL anti-violation guard

  `boot_at_start?/1` only allows a fleet_spawner boot if
  `boot_at_start: true` **AND** `lifetime_scope: forever` **AND**
  `host_native != true`. The 3rd term is the **anti-violation guard**:
  `starfleet` (host_native: true, canon derogation) must NEVER
  be spawned via fleet_spawner bwrap
  (it boots separately, host-native outside fleet_spawner — `host_launch.sh`,
  containment: none). Defensive guard even if a host_native profile carried
  `boot_at_start: true` by mistake.

  ## String keys, not atom

  The real `%Fleet.CapProfile{}` has `spec :: map()` with **string
  keys** (cf. `cap_profile.ex`, `spec: Map.get(raw, "spec", %{})`).
  Coding atom-keys (`get_in(cp, [:spec, :invocation, ...])`) → `nil` →
  0 pod booted silently. Hence the string-keyed access here.

  """

  require Logger

  # AUTHORITY of the permanent pod_id prefix ("permanent-<role>", deterministic id). Typed ONCE:
  # PermanentWarden (detection of dead pods to respawn) and Shutdown (drain that EXCLUDES the
  # residents) DERIVE from it — before, the literal lived in 3 modules.
  @permanent_prefix "permanent-"

  @doc """
  Parses a permanent pod_id: `{:ok, role}` if `permanent-<role>`, `:not_permanent` otherwise.
  THE prefix match lives here (single authority) — consumers pattern-match the result.
  """
  @spec parse_permanent(String.t()) :: {:ok, String.t()} | :not_permanent
  def parse_permanent(@permanent_prefix <> role) when role != "", do: {:ok, role}
  def parse_permanent(_), do: :not_permanent

  @doc "true if the pod_id is that of a PERMANENT pod (resident — not in-flight work)."
  @spec permanent?(String.t()) :: boolean()
  def permanent?(pod_id) when is_binary(pod_id), do: match?({:ok, _}, parse_permanent(pod_id))

  @doc """
  Should this cap-profile boot at fleet startup (Type 1)?

  `true` iff `spec.invocation.boot_at_start == true` AND
  `spec.invocation.lifetime_scope == "forever"` AND
  **`spec.invocation.host_native != true`** (anti-violation guard).
  """
  @spec boot_at_start?(Fleet.CapProfile.t() | map()) :: boolean()
  def boot_at_start?(%Fleet.CapProfile{spec: spec}), do: boot_at_start?(spec)

  def boot_at_start?(%{} = spec) do
    inv = Map.get(spec, "invocation", %{})

    Map.get(inv, "boot_at_start") == true and
      Map.get(inv, "lifetime_scope") == "forever" and
      Map.get(inv, "host_native") != true
  end

  def boot_at_start?(_), do: false

  @doc """
  Filters a list of cap-profiles → those eligible for Type 1 permanent
  boot (`boot_at_start?/1` guard applied, host_native excluded).
  """
  @spec select_permanent([Fleet.CapProfile.t()]) :: [Fleet.CapProfile.t()]
  def select_permanent(cap_profiles) when is_list(cap_profiles) do
    Enum.filter(cap_profiles, &boot_at_start?/1)
  end

  @doc """
  Boot of the Type 1 permanent pods.
  Invoked post-readiness by the **single authority**
  `Fleet.Starfleet.BootOrchestrator` (the `Fleet.Spawner.Application` hook
  that also invoked it was removed to avoid double-boot).

  Enumerates the roles of the cap-profiles directory → delegates loading+
  validation to the canonical loader `Fleet.CapProfile.load/1` (DRY — no
  YAML re-parse) → `select_permanent/1` guard (host_native excluded) →
  `spawn_pod/3`
  (real signature `(%CapProfile{}, issue_id, opts)`).

  ## LOAD failure vs SPAWN failure

  **A cap-profile that does NOT LOAD** (missing / corrupt YAML / invalid schema) = broken
  deploy artifact → **fail-loud**: `boot_permanent_pods/1` returns `{:error, {:cap_profile_load_failed,
  role, reason}}` (BootOrchestrator → `fleet.boot_failed`, not an amputated-green `boot_complete`). Without
  the fail-loud, these failures would be dropped silently — the "wounded thing kept
  alive" that the doctrine rejects.

  **A SPAWN failure** (bwrap/launch KO) does NOT stop the others (each one tries), but is NO LONGER
  silently filtered: it is returned as `{:error, {role, reason}}` in the results list →
  the BootOrchestrator emits `fleet.boot_partial` (the missing permanent is NAMED, no
  amputated-green `boot_complete`). Jupiter-grade: nobody runs behind it with a checklist —
  the boot tells the truth itself, and the `PermanentWarden` retries on `pod.failed`.

  ## Single writer state.json

  PermanentBoot **spawns** but **does NOT write** `state.json` — the write is
  delegated to the `gen_statem` `Fleet.Spawner.Pod` (via `Pod.StateFs.write_state_fs/1`). A single
  writer: no parallel `:state_writer` seam.

  ## Seams (IO decoupling for tests)
    * `:cap_profiles_dir` — scanned directory (config default
      `:fleet_spawner, :cap_profiles_dir`)
    * `:loader` — `(role :: String.t()) -> {:ok, cp} | {:error, term}`
      (default `&Fleet.CapProfile.load/1`)
    * `:spawner` — `(cp, issue_id, opts) -> {:ok, pid} | {:error, term}`
      (default `&Fleet.Spawner.spawn_pod/3`)
  """
  # Returns the RESULTS LIST `[{:ok, pod_id} | {:error, {role, reason}}]` — a failed spawn
  # is NO LONGER filtered (the old `reject(&is_nil/1)` returned `{:ok, partial_list}` → LYING boot).
  # `safe_boot` (BootOrchestrator) classifies the list natively: all-ok → boot_complete, mixed →
  # boot_partial. GLOBAL error (broken deploy) → `{:error, reason}` unchanged (→ boot_failed).
  @spec boot_permanent_pods(keyword()) ::
          [{:ok, String.t()} | {:error, {String.t(), term()}}] | {:error, term()}
  def boot_permanent_pods(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    with {:ok, roles} <- list_roles(dir),
         {:ok, cps} <- load_all(roles, loader) do
      cps
      |> select_permanent()
      |> Enum.map(&spawn_one(&1, spawner))
    else
      # A failed load = broken deploy → we propagate it as-is (fail-loud). Distinct from the
      # unreadable dir (`list_roles`), classified `:cap_profiles_dir_unreadable`.
      {:error, {:cap_profile_load_failed, _role, _reason}} = err ->
        err

      {:error, reason} ->
        {:error, {:cap_profiles_dir_unreadable, reason}}
    end
  end

  @doc """
  Re-spawn ONE dead permanent pod (rebuildable cattle) — called by `Fleet.Spawner.PermanentWarden`
  on `pod.failed` of a `permanent-<role>` pod. Reuses EXACTLY the boot path (`spawn_one`):
  deterministic idempotent pod_id (`{:already_started}` = no-op if the pod came back in the meantime) +
  boot-from-base if a base exists (stable UUID + FRESH context restored from the base — the respawn
  NEVER resumes the dead pod's accumulated session, consistent with the fresh-reroll recovery).

  Safeguard: the loaded cap-profile must be a PERMANENT (`boot_at_start?`) — fail-loud refusal otherwise
  (a non-permanent role has no business here, even if a forged `permanent-*` pod_id asked for it).

  Returns `{:ok, pod_id}` | `{:error, {role, reason}}`.
  """
  @spec respawn(String.t(), keyword()) :: {:ok, String.t()} | {:error, {String.t(), term()}}
  def respawn(role, opts \\ []) when is_binary(role) and is_list(opts) do
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.load/1)
    spawner = Keyword.get(opts, :spawner, &Fleet.Spawner.spawn_pod/3)

    case loader.(role) do
      {:ok, %Fleet.CapProfile{} = cp} ->
        if boot_at_start?(cp.spec),
          do: spawn_one(cp, spawner),
          else: {:error, {role, :not_a_permanent}}

      {:error, reason} ->
        {:error, {role, {:cap_profile_load_failed, reason}}}
    end
  end

  @doc """
  Is permanent-pod boot enabled? Config `:fleet_spawner,
  :boot_permanent_at_start` — **default `true`** ("default true in prod, false in
  test"; `false` disables). Pure,
  testable (gate decoupled from spawn IO).

  This predicate is the **single canon gate** for permanent-pod
  boot, consulted by `Fleet.Starfleet.BootOrchestrator` (the single boot
  authority). `LCARS_BOOT_PERMANENT_AT_START=false` (runtime.exs) sets it to
  `false` → BootOrchestrator wires the consumers + emits `fleet.boot_complete` but
  spawns NO permanent pod (explicit degraded/maintenance mode). The default
  (env absent) = `true` = boots — nominal prod behavior.
  """
  @spec auto_boot_enabled?() :: boolean()
  def auto_boot_enabled? do
    Application.get_env(:fleet_spawner, :boot_permanent_at_start, true) == true
  end

  # `persist_state/2` removed — "single writer" rule: only
  # `Fleet.Spawner.Pod.StateFs.write_state_fs/1` (called by the `Pod`) writes `state.json`. PermanentBoot
  # spawns the Pod and delegates the write to the gen_statem.

  # --- private ---

  defp cap_profiles_dir do
    # SINGLE source aligned on the LOADER (`Fleet.CapProfile.root_dir`) — otherwise
    # PermanentBoot ENUMERATES one dir (`05_data-canon/cap-profiles`) while `Fleet.CapProfile.load`
    # LOADS from another (`cap-profiles`) → a listed profile is not loadable (enum/load
    # mismatched). The override `:fleet_spawner, :cap_profiles_dir` stays (tests/non-standard deployment).
    Application.get_env(:fleet_spawner, :cap_profiles_dir) || Fleet.CapProfile.root_dir()
  end

  # Enumerates via the SINGLE SOURCE `Fleet.CapProfile.list/1` — by the
  # `metadata.name` prop, never by filename. Enum and `load` thus share the SAME key
  # (the name) → no more enum↔load mismatch (a listed profile is always loadable).
  defp list_roles(dir) do
    Fleet.CapProfile.list(dir)
  end

  # Loads ALL roles, short-circuits on the FIRST load failure (fail-loud, no more silent
  # skip). Thus validates the whole catalogue at boot — a corrupt profile is caught before it is
  # even needed. (The permanent filtering comes AFTER, on the loaded cps.)
  defp load_all(roles, loader) do
    case Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, acc} ->
           case loader.(role) do
             {:ok, %Fleet.CapProfile{} = cp} ->
               {:cont, {:ok, [cp | acc]}}

             {:error, reason} ->
               Logger.error(
                 "PermanentBoot: cap-profile #{role} not loadable (#{inspect(reason)}) — boot fail-loud"
               )

               {:halt, {:error, {:cap_profile_load_failed, role, reason}}}
           end
         end) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp spawn_one(%Fleet.CapProfile{} = cp, spawner) do
    name = Fleet.CapProfile.name(cp)

    # DETERMINISTIC pod_id (stable, no timestamp suffix) → idempotent re-spawn (same id: reap-orphan +
    # relaunch if dead, `{:already_started}` no-op if alive; no more holder-leak/accumulation).
    pod_id = @permanent_prefix <> name

    # If a base exists for this role → boot-from-base (FIXED UUID carried by
    # the base + restore + `--resume`) → a UNIQUE Claude Desktop entry reused at each boot + FRESH
    # context (the base captured out-of-fleet, not the accumulated session of the previous run). Otherwise → recreate
    # (new session, default behavior). Distinct from CRASH recovery (which never resumes
    # a session — it rerolls FRESH); here it is the clean DELIBERATE boot.
    opts = boot_opts(name, pod_id)

    case spawner.(cp, pod_id, opts) do
      {:ok, _pid} ->
        {:ok, pod_id}

      {:error, {:already_started, _pid}} ->
        Logger.info(
          "PermanentBoot: permanent #{name} already alive (#{pod_id}) — idempotent no-op"
        )

        {:ok, pod_id}

      {:error, reason} ->
        # The failure is RETURNED (no more nil silently filtered) → boot_partial visible / respawn retry.
        Logger.error("PermanentBoot: spawn of permanent #{name} failed (#{inspect(reason)})")
        {:error, {name, reason}}
    end
  end

  # Spawn opts of a permanent.
  # Base present (`priv/base_seeds/<role>.jsonl`) → boot-from-base: FIXED UUID = the `sessionId` CARRIED by
  # the base (the base IS the source of the UUID, no separate config) → `--resume` that same UUID at each
  # boot = ONE Desktop entry, and `recall_seed_jsonl` restores the base BEFORE the launch = fresh context.
  # No base → `[pod_id:]` alone = recreate (new session).
  defp boot_opts(name, pod_id) do
    path = base_seed_path(name)

    cond do
      # No base = a FRESH permanent pod (nominal) → recreate, SILENT (normal, not an incident).
      not File.exists?(path) ->
        [pod_id: pod_id]

      is_binary(uuid = base_seed_uuid(path)) ->
        [pod_id: pod_id, session_id: uuid, resume: true, recall_seed_jsonl: path]

      # F-C043 — base PRESENT but no valid session UUID (unreadable / no `sessionId`) = a CORRUPT versioned
      # seed. The permanent pod boots FRESH (a NEW Desktop entry each boot → accumulation, its STABLE
      # identity lost). We KEEP booting (availability > this non-safety optimization) but ESCALATE it as an
      # INCIDENT, not merely a log (user decision F-C043).
      true ->
        escalate_corrupt_seed(name, pod_id, path)
        [pod_id: pod_id]
    end
  end

  # F-C043 — a corrupt permanent base seed is a CERTAIN config problem (a versioned artifact in `priv` is
  # broken), not a probabilistic strike. We log LOUD and emit `pod.drift` (source `:spawner`) with
  # `drift_count` AT the DriftMonitor threshold → the anomaly rail (DriftMonitor → Cat5Escalator) escalates
  # it on the FIRST occurrence (an operator repairs the seed). Best-effort (`Bus.safe_emit`): the incident
  # signal never blocks/crashes the boot — the pod still comes up (degraded).
  # @drift_escalate_count must be ≥ `Fleet.Starfleet.DriftMonitor`'s threshold (3, a protocol constant;
  # fleet_spawner→fleet_starfleet is not a dependency, so it is asserted by a comment, not referenced).
  @drift_escalate_count 3
  @doc false
  def escalate_corrupt_seed(name, pod_id, path) do
    Logger.error(
      "PermanentBoot: base seed #{path} (role #{name}) present but NO valid session UUID — booting a " <>
        "FRESH session (new Desktop entry each boot, accumulation, stable identity lost). Escalating as " <>
        "INCIDENT (pod.drift → Cat5). FIX the versioned seed."
    )

    _ =
      Fleet.EventRouter.Bus.safe_emit(
        :spawner,
        :"pod.drift",
        [
          payload: %{
            "pod_id" => pod_id,
            "role" => name,
            "drift_count" => @drift_escalate_count,
            "reason" => "base_seed_corrupt",
            "path" => path,
            "detail" =>
              "permanent base seed present but no valid session UUID — booting fresh (Desktop-entry accumulation)"
          }
        ],
        on_unregistered: :log,
        context: "PermanentBoot corrupt base seed (role #{name})"
      )

    :ok
  end

  # Base seed of a permanent: clean resumable anchor, captured out-of-fleet (pure claude), versioned in priv.
  defp base_seed_path(name) do
    Path.join([:code.priv_dir(:fleet_spawner), "base_seeds", "#{name}.jsonl"])
  end

  # Fixed UUID = 1st `sessionId` found in the base. nil if absent (→ boot_opts falls back to recreate).
  defp base_seed_uuid(path) do
    path
    |> File.stream!()
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"sessionId" => uuid}} when is_binary(uuid) -> uuid
        _ -> nil
      end
    end)
  rescue
    # Unreadable base (permission / truncated file) → nil. A MISSING base is normal (fresh permanent pod)
    # and is filtered UPSTREAM by `boot_opts` (`File.exists?`); a PRESENT-but-unreadable/invalid base is the
    # CORRUPT case → `boot_opts` escalates it (F-C043, `escalate_corrupt_seed`), the single log+incident site.
    _e -> nil
  end
end
