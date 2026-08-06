defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Boot of the fleet-level Type 1 permanent pods **at startup of the fleet_v2
  runtime launched by the human** (`bin/fleet_v2 start` starts the BEAM under
  the human's UID, then this module boots every pod whose cap-profile declares
  `boot_at_start: true` — the human-launches model, no system service). WHICH
  roles are permanent is the CATALOGUE's declaration, never this module's: the
  architect, in particular, is per-project (spawned at onboarding), not a Type 1.


  ## CRITICAL anti-violation guard

  `boot_at_start?/1` only allows a fleet_spawner boot if
  `boot_at_start: true` **AND** `lifetime_scope: forever` **AND**
  `host_native != true`. The 3rd term is the **anti-violation guard**: a host_native profile
  boots separately, host-native OUTSIDE fleet_spawner (`bin/host_launch.sh`, containment: none) —
  it must NEVER be spawned via fleet_spawner bwrap. Since the 2026-07-19 reorg no canon profile is
  host_native (starfleet became an ordinary bwrap orchestrator), so this term is now a purely
  DEFENSIVE guard: it still fails-closed should a host_native profile ever carry
  `boot_at_start: true` (a future off-fleet role, or a config mistake).

  ## String keys, not atom

  The real `%Fleet.CapProfile{}` has `spec :: map()` with **string
  keys** (cf. `cap_profile.ex`, `spec: Map.get(raw, "spec", %{})`).
  Coding atom-keys (`get_in(cp, [:spec, :invocation, ...])`) → `nil` →
  0 pod booted silently. Hence the string-keyed access here.

  **Last revised**: 2026-08-05

  """

  require Logger

  # AUTHORITY of the permanent pod_id prefix ("permanent-<role>", deterministic id). Typed ONCE:
  # PermanentWarden (detection of dead pods to respawn) and Shutdown (drain that EXCLUDES the
  # residents) DERIVE from it.
  @permanent_prefix "permanent-"

  @doc """
  Parses a permanent pod_id: `{:ok, role}` if `permanent-<role>`, `:not_permanent` otherwise.
  THE prefix match lives here (single authority) — consumers pattern-match the result.
  """
  @spec parse_permanent(String.t()) :: {:ok, String.t()} | :not_permanent
  def parse_permanent(@permanent_prefix <> role) when role != "", do: {:ok, role}
  def parse_permanent(_), do: :not_permanent

  @doc """
  Builds a permanent pod_id from its role — the CONSTRUCTOR half of the same authority.

  The prefix was typed once and readable only backwards: consumers could recognize a permanent
  pod_id, and anyone needing to NAME one (a feed addressing the front desk, say) had to retype the
  literal. One authority, both directions.
  """
  @spec pod_id_for(String.t()) :: String.t()
  def pod_id_for(role) when is_binary(role) and role != "", do: @permanent_prefix <> role

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
  `Fleet.Starfleet.BootOrchestrator` (`Fleet.Spawner.Application` boots no
  permanent pod — one boot authority, no double-boot possible).

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
  # is NEVER filtered out (a filtered partial list would be a LYING boot).
  # `safe_boot` (BootOrchestrator) classifies the list natively: all-ok → boot_complete, mixed →
  # boot_partial. GLOBAL error (broken deploy) → `{:error, reason}` unchanged (→ boot_failed).
  @spec boot_permanent_pods(keyword()) ::
          [{:ok, String.t()} | {:error, {String.t(), term()}}] | {:error, term()}
  def boot_permanent_pods(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.resolve(Fleet.CapProfile, &1))
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
  Roles EXPECTED to run as permanents = the catalogue's `boot_at_start?` cap-profiles.

  The SAME selection as `boot_permanent_pods/1` (one authority for "who is permanent"), exposed so
  the `PermanentWarden` can reconcile expectation against the live Registry — a permanent that dies
  WITHOUT emitting `pod.failed` (clean sub-tree restart, lost lossy event) is invisible to the
  event rail. A role whose profile no longer loads is NOT listed (the fail-loud belongs to boot;
  a reconciliation tick must not respawn from a broken artefact — but it logs a warning per
  tick so the exclusion is never silent: no permanent vanishes from reconciliation without a trace).

  Seams `:cap_profiles_dir` / `:loader` — same as `boot_permanent_pods/1`.
  """
  @spec expected_permanent_roles(keyword()) :: [String.t()]
  def expected_permanent_roles(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :cap_profiles_dir) || cap_profiles_dir()
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.resolve(Fleet.CapProfile, &1))

    case list_roles(dir) do
      {:ok, roles} ->
        Enum.flat_map(roles, fn role ->
          case loader.(role) do
            {:ok, %Fleet.CapProfile{} = cp} ->
              if boot_at_start?(cp.spec), do: [role], else: []

            {:error, reason} ->
              # The exclusion is DELIBERATE (never respawn from a broken artefact) but must not be
              # SILENT: a permanent whose profile breaks AFTER boot would otherwise vanish from the
              # reconciliation with no trace — dead and never respawned, and nobody told. The warden
              # ticks, so this fires once per tick while the artefact stays broken: loud by design.
              Logger.warning(
                "PermanentBoot: role #{role} EXCLUDED from permanent reconciliation — its " <>
                  "cap-profile no longer loads (#{inspect(reason)}); it will NOT be respawned " <>
                  "until the artefact is repaired"
              )

              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Re-spawn ONE dead permanent pod (rebuildable cattle) — called by `Fleet.Spawner.PermanentWarden`
  on `pod.failed` of a `permanent-<role>` pod. Reuses EXACTLY the boot path (`spawn_one`):
  deterministic idempotent pod_id (`{:already_started}` = no-op if the pod came back in the meantime) +
  a stable UUID + a FRESH context (recreated from scratch, no base seed — the respawn
  NEVER resumes the dead pod's accumulated session, consistent with the fresh-reroll recovery).

  Safeguard: the loaded cap-profile must be a PERMANENT (`boot_at_start?`) — fail-loud refusal otherwise
  (a non-permanent role has no business here, even if a forged `permanent-*` pod_id asked for it).

  Returns `{:ok, pod_id}` | `{:error, {role, reason}}`.
  """
  @spec respawn(String.t(), keyword()) :: {:ok, String.t()} | {:error, {String.t(), term()}}
  def respawn(role, opts \\ []) when is_binary(role) and is_list(opts) do
    loader = Keyword.get(opts, :loader, &Fleet.CapProfile.resolve(Fleet.CapProfile, &1))
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

  # --- private ---

  defp cap_profiles_dir do
    # SINGLE source aligned on the LOADER (`Fleet.CapProfile.root_dir`) — otherwise PermanentBoot
    # ENUMERATES one directory while `Fleet.CapProfile.load` LOADS from another, and a profile that
    # `list/1` returns is not loadable (enum/load mismatched). The override `:fleet_spawner, :cap_profiles_dir` stays (tests/non-standard deployment).
    Application.get_env(:fleet_spawner, :cap_profiles_dir) || Fleet.CapProfile.root_dir()
  end

  # Enumerates via the SINGLE SOURCE `Fleet.CapProfile.list/1` — by the
  # `metadata.name` prop, never by filename. Enum and `load` thus share the SAME key
  # (the name) → no more enum↔load mismatch (a listed profile is always loadable).
  defp list_roles(dir) do
    case Fleet.CapProfile.list_from_published() do
      {:ok, roles} -> {:ok, roles}
      {:error, :not_published} -> Fleet.CapProfile.list(dir)
    end
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
    pod_id = pod_id_for(name)

    # No boot-from-base anymore (reorg 2026-07-19): the pod itself runs the UNIFIED seed decision
    # at first boot (`Pod.maybe_slot_resume` — live jsonl → resume in place; captured seed →
    # resume from it; else fresh). PermanentBoot only names the pod — one seed authority, in the pod.
    case spawner.(cp, pod_id, pod_id: pod_id) do
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

  # There is no boot-from-base branch here: the pod's unified seed decision (`Pod.maybe_slot_resume` —
  # live jsonl / captured seed / fresh) is the ONLY resume authority, and the corrupt-seed rail died
  # with the artifact it guarded (reorg 2026-07-19). The absence is LOCKED and explained where it is
  # enforced — `permanent_boot_test.exs`, "the boot-from-base branch is GONE" — so read it there.
end
