defmodule Fleet.Spawner.PermanentBootTest do
  @moduledoc """
  Checks permanent selection, boot/respawn results and shipped-profile eligibility.
  Serial because tests change application configuration and published images.
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

  describe "the permanent pod_id — one authority, both directions" do
    test "build then parse round-trips: the constructor and the parser cannot drift apart" do
      for role <- ~w(starfleet architect engineer) do
        assert {:ok, ^role} = PermanentBoot.parse_permanent(PermanentBoot.pod_id_for(role))
      end
    end

    test "an ordinary pod_id is NOT permanent — the parser still refuses what it always refused" do
      assert :not_permanent = PermanentBoot.parse_permanent("fleet-demo-issue-3-engineer")
      assert :not_permanent = PermanentBoot.parse_permanent("permanent-")
    end
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
      # Enumeration reads metadata.name from these files; the injected loader supplies
      # the full profiles. host-native-probe is synthetic, not a shipped role.
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

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, o ->
        send(parent, {:spawned, n, tid, o})
        {:ok, spawn(fn -> :ok end)}
      end

      assert [{:ok, pid_perm}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )

      assert pid_perm == "permanent-starfleet"
      assert_received {:spawned, "starfleet", ^pid_perm, opts}
      refute_received {:spawned, "engineer", _, _}

      assert opts[:rc_name] == "starfleet"
      refute_received {:spawned, "host-native-probe", _}
    end

    test "BL-055: permanent already alive ({:already_started}) → idempotent no-op (pod_id kept)",
         %{dir: dir} do
      spawner = fn _cp, _tid, _o -> {:error, {:already_started, self()}} end

      assert [{:ok, "permanent-starfleet"}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )
    end

    test "a role whose profile BREAKS after boot is excluded from reconciliation LOUDLY, never silently",
         %{dir: dir} do
      loader = fn
        "starfleet" -> {:error, :invalid_schema}
        role -> loader_for().(role)
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          roles = PermanentBoot.expected_permanent_roles(cap_profiles_dir: dir, loader: loader)
          refute "starfleet" in roles
        end)

      assert log =~ "starfleet"
      assert log =~ "EXCLUDED from permanent reconciliation"
    end

    test "F-052: load {:error} on one role → fail-loud (broken deploy, no silent skip)",
         %{dir: dir} do
      # Roles are sorted, so engineer is the first profile load to fail.
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

    test "DPF-08: published cap-profile image preferred over disk scan (empty dir ignored)", %{
      dir: dir
    } do
      Fleet.CapProfile.Image.republish(%{
        index: %{"starfleet" => %{}},
        overlays: %{},
        version: "v-test"
      })

      on_exit(fn -> Fleet.CapProfile.Image.unpublish() end)

      empty_dir = Path.join(dir, "empty_subdir")
      File.mkdir_p!(empty_dir)

      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:spawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      assert [{:ok, "permanent-starfleet"}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: empty_dir,
                 loader: loader_for(),
                 spawner: spawner
               )

      assert_received {:spawned, "starfleet", "permanent-starfleet"}
    end
  end

  describe "REAL canon conformance — boot_at_start? on in-repo cap-profiles" do
    # Search both shipped catalogues: system and project roles live in separate roots.
    @canon_dirs [
      Application.app_dir(:lcars_fleet, "priv/catalogue-system/cap_profile/cap-profiles"),
      Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile/cap-profiles")
    ]

    defp canon_spec(name) do
      @canon_dirs
      |> Enum.map(&Path.join(&1, "#{name}.yaml"))
      |> Enum.find(&File.exists?/1)
      |> YamlElixir.read_from_file!()
      |> Map.get("spec")
    end

    test "starfleet.yaml (real canon) → boot_at_start? TRUE (the boot front-desk, reorg 2026-07-19)" do
      assert PermanentBoot.boot_at_start?(canon_spec("starfleet"))
    end

    test "architect.yaml (real canon) → boot_at_start? FALSE (per-project, spawned on-open not at boot)" do
      refute PermanentBoot.boot_at_start?(canon_spec("architect")),
             "canon architect is boot_at_start:false — per-project, spawned on-open, not a permanent"
    end

    test "engineer.yaml (real canon) → boot_at_start? FALSE (one-shot worker)" do
      refute PermanentBoot.boot_at_start?(canon_spec("engineer"))
    end

    test "select_permanent on the 7 canon cap-profiles → starfleet alone" do
      profiles =
        ~w(architect engineer gatekeeper qualifier reviewer scoper starfleet)
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

  describe "auto_boot_enabled?/0 — canon gate for permanent-pod boot (default true)" do
    test "default true (unconfigured) — boots by default, DN canon" do
      assert PermanentBoot.auto_boot_enabled?()
    end

    test "false only if :boot_permanent_at_start is explicitly set to false" do
      Application.put_env(:lcars_fleet, :spawner_boot_permanent_at_start, false)
      on_exit(fn -> Application.delete_env(:lcars_fleet, :spawner_boot_permanent_at_start) end)
      refute PermanentBoot.auto_boot_enabled?()

      Application.put_env(:lcars_fleet, :spawner_boot_permanent_at_start, true)
      assert PermanentBoot.auto_boot_enabled?()

      Application.put_env(:lcars_fleet, :spawner_boot_permanent_at_start, "yes")
      refute PermanentBoot.auto_boot_enabled?()
    end
  end

  test "the boot-from-base branch is GONE (reorg 2026-07-19 — one seed authority, in the pod)" do
    # Recovery decisions belong to Pod; PermanentBoot does not inject a base seed.
    refute function_exported?(PermanentBoot, :escalate_corrupt_seed, 3)

    refute File.exists?(
             Path.join([:code.priv_dir(:lcars_fleet), "spawner", "base_seeds", "architect.jsonl"])
           )
  end
end
