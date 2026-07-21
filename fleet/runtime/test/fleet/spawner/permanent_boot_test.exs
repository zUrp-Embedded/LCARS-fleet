defmodule Fleet.Spawner.PermanentBootTest do
  @moduledoc """
  Lot 3 inc1 — `Fleet.Spawner.PermanentBoot.boot_at_start?/1` CRITICAL D-01
  guard (DN ring1/permanent-pods-boot.md). Pure, string-keyed
  (anti-M1: the DN's atom-keyed pseudo-code = illustrative).

  `async: false`: the `auto_boot_enabled?/0` describe mutates global Application
  config (`:boot_permanent_at_start`) via `put_env` — runtime-config coupling
  inherent to the predicate; serializing avoids the inter-module race (BL-028).
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.PermanentBoot

  defp cp(invocation) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "x"},
      spec: %{"invocation" => invocation}
    }
  end

  describe "boot_at_start?/1 — Type 1 fleet-level" do
    test "true: boot_at_start true + forever + host_native false (starfleet)" do
      assert PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => true,
                 "lifetime_scope" => "forever",
                 "host_native" => false
               })
             )
    end

    test "true: host_native absent (non-D-01 default)" do
      assert PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => true, "lifetime_scope" => "forever"})
             )
    end

    test "false: boot_at_start false (engineer one-shot worker)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => false, "lifetime_scope" => "one-shot"})
             )
    end

    test "false: boot_at_start true but lifetime_scope != forever (inconsistent G24-10)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => true, "lifetime_scope" => "one-shot"})
             )
    end
  end

  describe "CRITICAL D-01 guard — host_native excluded" do
    test "false: host_native profile with boot_at_start false — NEVER fleet_spawner" do
      refute PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => false,
                 "lifetime_scope" => "forever",
                 "host_native" => true
               })
             )
    end

    test "DEFENSIVE false: host_native true EVEN IF boot_at_start true (anti D-01 violation)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => true,
                 "lifetime_scope" => "forever",
                 "host_native" => true
               })
             ),
             "host_native:true must NEVER boot via fleet_spawner (D-01), " <>
               "even with a misconfigured boot_at_start:true"
    end
  end

  describe "input robustness" do
    test "spec without invocation → false" do
      assert PermanentBoot.boot_at_start?(%Fleet.CapProfile{
               kind: "k",
               metadata: %{},
               spec: %{}
             }) == false
    end

    test "non-struct/non-map → false" do
      refute PermanentBoot.boot_at_start?(nil)
      refute PermanentBoot.boot_at_start?("garbage")
    end

    test "accepts a bare spec map (string-keyed)" do
      assert PermanentBoot.boot_at_start?(%{
               "invocation" => %{"boot_at_start" => true, "lifetime_scope" => "forever"}
             })
    end
  end

  describe "select_permanent/1" do
    test "keeps only Type 1, excludes D-01 + workers" do
      profiles = [
        cp(%{"boot_at_start" => true, "lifetime_scope" => "forever", "host_native" => false}),
        cp(%{"boot_at_start" => false, "lifetime_scope" => "one-shot"}),
        cp(%{"boot_at_start" => true, "lifetime_scope" => "forever", "host_native" => true})
      ]

      assert [%Fleet.CapProfile{spec: %{"invocation" => %{"host_native" => false}}}] =
               PermanentBoot.select_permanent(profiles)
    end

    test "empty list → []" do
      assert PermanentBoot.select_permanent([]) == []
    end
  end

  describe "boot_permanent_pods/1 (injected seams — deterministic)" do
    @describetag :tmp_dir
    setup %{tmp_dir: dir} do
      # The enumerator (`CapProfile.list`) resolves by `metadata.name` → yaml fixtures carrying the
      # name (the indexable identity). The FULL content comes from the injected loader (`loader_for`).
      # `notes.txt` = non-.yaml, ignored by the scan.
      #
      # WHY THESE NAMES — they used to say the opposite of the canon, and the conformance describe at the
      # bottom of this file proves which way is true: `starfleet` is the Type 1 permanent that boots,
      # the architect is PER-PROJECT (`boot_at_start: false`, spawned on-open), and NO canon role is
      # host-native since the reorg. So the booting fixture is `starfleet`, and the D-01 exclusion is
      # probed with a SYNTHETIC `host-native-probe`: the guard must be exercised, and no real role can
      # exercise it any more. Naming it after a real role is what made this file teach a dead topology.
      for name <- ~w(engineer host-native-probe starfleet) do
        File.write!(Path.join(dir, "#{name}.yaml"), "metadata:\n  name: #{name}\n")
      end

      File.write!(Path.join(dir, "notes.txt"), "x")

      {:ok, dir: dir}
    end

    defp loader_for do
      fn
        "starfleet" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "starfleet"},
             spec: %{
               "invocation" => %{
                 "boot_at_start" => true,
                 "lifetime_scope" => "forever",
                 "host_native" => false
               }
             }
           }}

        "engineer" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "engineer"},
             spec: %{"invocation" => %{"boot_at_start" => false, "lifetime_scope" => "one-shot"}}
           }}

        "host-native-probe" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "host-native-probe"},
             spec: %{
               "invocation" => %{
                 "boot_at_start" => false,
                 "lifetime_scope" => "forever",
                 "host_native" => true
               }
             }
           }}
      end
    end

    test "spawns ONLY starfleet (engineer worker + host-native-probe D-01 excluded)",
         %{dir: dir} do
      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:spawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      # G9: the boot returns the RESULT LIST (the BootOrchestrator's safe_boot classifies it).
      assert [{:ok, pid_perm}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )

      # BL-055: DETERMINISTIC permanent pod_id (no `-<os_time>`) → idempotent.
      assert pid_perm == "permanent-starfleet"
      assert_received {:spawned, "starfleet", ^pid_perm}
      refute_received {:spawned, "engineer", _}
      refute_received {:spawned, "host-native-probe", _}
    end

    test "BL-055: permanent already alive ({:already_started}) → idempotent no-op (pod_id kept)",
         %{dir: dir} do
      # deterministic id → a re-boot lands back on `permanent-starfleet`; if the pod already runs,
      # spawn_pod returns {:already_started} → this is NOT an error, the pod_id is kept.
      spawner = fn _cp, _tid, _o -> {:error, {:already_started, self()}} end

      assert [{:ok, "permanent-starfleet"}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )
    end

    test "F-052: load {:error} on one role → fail-loud (broken deploy, no silent skip)",
         %{dir: dir} do
      # Crash-boot doctrine: an unloadable profile = broken artifact → propagate (a "partial
      # success" that skips invalid roles and boots the rest would hide a broken deploy).
      # `list_roles` returns sorted roles → engineer is the 1st to fail (starfleet OK).
      loader = fn
        "starfleet" -> loader_for().("starfleet")
        _ -> {:error, :invalid_schema}
      end

      assert {:error, {:cap_profile_load_failed, "engineer", :invalid_schema}} =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader,
                 spawner: fn _cp, _t, _o -> {:ok, self()} end
               )
    end

    test "G9 HONEST boot: spawner {:error} → the failure is RETURNED named, never filtered", %{
      dir: dir
    } do
      # G9: a swallowed starfleet spawn failure ({:ok, []} via reject nil) would make the
      # BootOrchestrator emit a LYING fleet.boot_complete. The failure lives in the result
      # list, named (role + reason) → safe_boot classifies it → fleet.boot_partial.
      assert [{:error, {"starfleet", :launch_failed}}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: fn _cp, _t, _o -> {:error, :launch_failed} end
               )
    end

    test "G5 respawn/2: re-spawn of ONE permanent via the boot path (idempotent)", %{dir: _dir} do
      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:respawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      assert {:ok, "permanent-starfleet"} =
               PermanentBoot.respawn("starfleet", loader: loader_for(), spawner: spawner)

      assert_received {:respawned, "starfleet", "permanent-starfleet"}
    end

    test "G5 respawn/2: guardrail — a NON-permanent role is refused fail-loud" do
      # engineer (boot_at_start: false): even if a forged `permanent-engineer` pod_id asked for it,
      # respawn refuses — a one-shot worker has no business in the permanent cycle.
      assert {:error, {"engineer", :not_a_permanent}} =
               PermanentBoot.respawn("engineer",
                 loader: loader_for(),
                 spawner: fn _c, _t, _o -> flunk("must not spawn") end
               )
    end

    test "G5 respawn/2: unreadable cap-profile → {:error, {role, {:cap_profile_load_failed, _}}}" do
      assert {:error, {"starfleet", {:cap_profile_load_failed, :corrupt}}} =
               PermanentBoot.respawn("starfleet",
                 loader: fn _ -> {:error, :corrupt} end,
                 spawner: fn _c, _t, _o -> flunk("must not spawn") end
               )
    end

    test "unreadable directory → {:error,{:cap_profiles_dir_unreadable,_}}" do
      assert {:error, {:cap_profiles_dir_unreadable, _}} =
               PermanentBoot.boot_permanent_pods(cap_profiles_dir: "/nonexistent/dir/x")
    end
  end

  describe "REAL canon conformance — boot_at_start? on in-repo cap-profiles" do
    # R0.8-brick5: canon lives in-repo (R0.7) at `priv/cap_profile/
    # canon/cap-profiles/`. No hardcoded doctrine path `05_data-canon/...`
    # (nonexistent in a standard install). Same pattern as brick1
    # MonkTest (resolve via Application.app_dir).
    @canon_dir Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/cap-profiles")

    defp canon_spec(name) do
      @canon_dir
      |> Path.join("#{name}.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.get("spec")
    end

    test "starfleet.yaml (real canon) → boot_at_start? TRUE (the boot front-desk, reorg 2026-07-19)" do
      assert PermanentBoot.boot_at_start?(canon_spec("starfleet"))
    end

    test "architect.yaml (real canon) → boot_at_start? FALSE (per-project, spawned on-open not at boot)" do
      # Since the 2026-07-19 reorg the architect is per-project: starfleet is the boot front-desk, the arch
      # is spawned on-open by create_project/relaunch — never at fleet boot.
      refute PermanentBoot.boot_at_start?(canon_spec("architect")),
             "canon architect is boot_at_start:false — per-project, spawned on-open, not a permanent"
    end

    test "engineer.yaml (real canon) → boot_at_start? FALSE (one-shot worker)" do
      refute PermanentBoot.boot_at_start?(canon_spec("engineer"))
    end

    test "select_permanent on the 7 canon cap-profiles → starfleet alone" do
      profiles =
        ~w(architect consultant engineer gatekeeper qualifier reviewer starfleet)
        |> Enum.map(fn n ->
          %Fleet.CapProfile{
            kind: "CapabilityProfile",
            metadata: %{"name" => n},
            spec: canon_spec(n)
          }
        end)

      selected = PermanentBoot.select_permanent(profiles)
      assert [%Fleet.CapProfile{metadata: %{"name" => "starfleet"}}] = selected
    end
  end

  # BL-028: `auto_boot_enabled?/0` IS the canon gate for booting permanent pods
  # (consulted by BootOrchestrator, single authority — F-14).
  # Default **true** (DN lcars-fleet_service §391); `false` disables.
  describe "auto_boot_enabled?/0 — canon gate for permanent-pod boot (default true)" do
    test "default true (unconfigured) — boots by default, DN canon" do
      assert PermanentBoot.auto_boot_enabled?()
    end

    test "false only if :boot_permanent_at_start is explicitly set to false" do
      Application.put_env(:fleet_spawner, :boot_permanent_at_start, false)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :boot_permanent_at_start) end)
      refute PermanentBoot.auto_boot_enabled?()

      Application.put_env(:fleet_spawner, :boot_permanent_at_start, true)
      assert PermanentBoot.auto_boot_enabled?()

      # Only the boolean `true` enables (not a "yes" string).
      Application.put_env(:fleet_spawner, :boot_permanent_at_start, "yes")
      refute PermanentBoot.auto_boot_enabled?()
    end
  end

  test "the boot-from-base branch is GONE (reorg 2026-07-19 — one seed authority, in the pod)" do
    # Base seeds died with the reorg: the pod's unified seed decision (`maybe_slot_resume`: live
    # jsonl / captured graine / fresh) replaced them, and the F-C043 corrupt-seed rail died with
    # the artifact it guarded.
    refute function_exported?(PermanentBoot, :escalate_corrupt_seed, 3)

    refute File.exists?(
             Path.join([:code.priv_dir(:lcars_fleet), "spawner", "base_seeds", "architect.jsonl"])
           )
  end
end
