defmodule Fleet.Spawner.PermanentBoot do
  @moduledoc """
  Boot of the fleet-level Type 1 permanent pods **at startup of the fleet_v2
  runtime launched by the human** (`bin/fleet_v2 start` starts the BEAM under
  the human's UID, then this module boots every pod whose cap-profile declares
  `boot_at_start: true` — the human-launches model, no system service). WHICH
  roles are permanent is the CATALOGUE's declaration, never this module's: the
  architect, in particular, is per-project (spawned at onboarding), not a Type 1.


  ## CRITICAL anti-violation guard

  `boot_at_start?/1` only allows a spawner boot if
  `boot_at_start: true` **AND** `lifetime_scope: forever` **AND**
  `host_native != true`. The 3rd term is the **anti-violation guard**: a host_native profile
  boots separately, host-native OUTSIDE the spawner (`bin/host_launch.sh`, containment: none) —
  it must NEVER be spawned through the spawner's bwrap.

  ⚠ THIS TERM IS LOAD-BEARING, NOT A LEFTOVER, and reading it as vestigial is the mistake that
  would spend it. A canon profile IS host_native: `admiral`, the machine seat — `containment: none`
  and `host_native: true`. It stays out of the boot only because it also carries
  `boot_at_start: false`, one line in a catalogue an operator is entitled to replace. Flipping that
  line is a plausible wish ("the seat should be up at boot"); this term is the only thing standing
  between that wish and a host-native profile launched through bwrap. It fails closed. Keep it.

  ## String keys, not atom

  The real `%Fleet.CapProfile{}` has `spec :: map()` with **string
  keys** (cf. `cap_profile.ex`, `spec: Map.get(raw, "spec", %{})`).
  Coding atom-keys (`get_in(cp, [:spec, :invocation, ...])`) → `nil` →
  0 pod booted silently. Hence the string-keyed access here.

  """

  require Logger

  # AUTHORITY of the permanent pod_id prefix ("permanent-<role>", deterministic id). Typed ONCE,
  # parsed by `PermanentWarden` alone.
  #
  # WHAT THE PREFIX IS FOR, and it is not sorting: the kill/harvest tier already has a carrier, the
  # `<X>` nibble of the session_id, greppable from a shell on a process cmdline. This prefix answers
  # a different question in a different place — the warden receives a `pod.failed` EVENT whose
  # payload carries the `pod_id` and nothing else, no cap-profile. Parsing it is how the ROLE
  # survives into a respawn. The prefix is a carrier of information in a channel that transports no
  # other, which is why it is not redundant with the nibble.
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

  @doc "Filters profiles through `boot_at_start?/1`."
  @spec select_permanent([Fleet.CapProfile.t()]) :: [Fleet.CapProfile.t()]
  def select_permanent(cap_profiles) when is_list(cap_profiles) do
    Enum.filter(cap_profiles, &boot_at_start?/1)
  end

  @doc """
  Loads the full catalogue, selects eligible profiles and attempts every spawn.

  A load failure returns `{:error, {:cap_profile_load_failed, role, reason}}` and stops
  boot. Spawn results remain in the returned list as `{:ok, pod_id}` or
  `{:error, {role, reason}}`. Options may inject the catalogue directory, loader and spawner.
  """
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
      {:error, {:cap_profile_load_failed, _role, _reason}} = err ->
        err

      {:error, reason} ->
        {:error, {:cap_profiles_dir_unreadable, reason}}
    end
  end

  @doc """
  Returns eligible permanent roles for reconciliation.

  An unloadable profile is excluded and logged rather than respawned from a broken artifact.
  Options may inject the catalogue directory and loader.
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
  Respawns one eligible permanent through the normal boot path. Already-running pods are
  idempotent successes; non-permanent and unloadable roles return named errors.
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

  @doc "Returns `:lcars_fleet, :spawner_boot_permanent_at_start`, defaulting to `true`."
  @spec auto_boot_enabled?() :: boolean()
  def auto_boot_enabled? do
    Application.get_env(:lcars_fleet, :spawner_boot_permanent_at_start, true) == true
  end

  defp cap_profiles_dir do
    Application.get_env(:lcars_fleet, :spawner_cap_profiles_dir) || Fleet.CapProfile.root_dir()
  end

  defp list_roles(dir) do
    case Fleet.CapProfile.list_from_published() do
      {:ok, roles} -> {:ok, roles}
      {:error, :not_published} -> Fleet.CapProfile.list(dir)
    end
  end

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
    # `rc_name` is what a HUMAN reads in Desktop, and this was the one spawn site that passed none
    # — the default falls back to a technical string, so the fleet's most visible pod was the only
    # one showing an internal key. The pod_id addresses, the session_id identifies to the vendor,
    # the rc_name is read: three strings, three jobs, and only this one faces a person.
    case spawner.(cp, pod_id, pod_id: pod_id, rc_name: Fleet.Layout.pod_label(nil, name, nil)) do
      {:ok, _pid} ->
        {:ok, pod_id}

      {:error, {:already_started, _pid}} ->
        Logger.info(
          "PermanentBoot: permanent #{name} already alive (#{pod_id}) — idempotent no-op"
        )

        {:ok, pod_id}

      {:error, reason} ->
        Logger.error("PermanentBoot: spawn of permanent #{name} failed (#{inspect(reason)})")
        {:error, {name, reason}}
    end
  end
end
