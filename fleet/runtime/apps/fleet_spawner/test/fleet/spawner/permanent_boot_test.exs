defmodule Fleet.Spawner.PermanentBootTest do
  @moduledoc """
  Lot 3 inc1 — `Fleet.Spawner.PermanentBoot.boot_at_start?/1` garde D-01
  CRITIQUE (DN ring1/permanent-pods-boot.md). Pur, string-keyed
  (anti-M1 : pseudo-code DN atom-keys = illustratif). `async: true`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PermanentBoot

  defp cp(invocation) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "x"},
      spec: %{"invocation" => invocation}
    }
  end

  describe "boot_at_start?/1 — Type 1 fleet-level" do
    test "true : boot_at_start true + forever + host_native false (architect-interactive)" do
      assert PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => true,
                 "lifetime_scope" => "forever",
                 "host_native" => false
               })
             )
    end

    test "true : host_native absent (défaut non-D-01)" do
      assert PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => true, "lifetime_scope" => "forever"})
             )
    end

    test "false : boot_at_start false (engineer worker one-shot)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => false, "lifetime_scope" => "one-shot"})
             )
    end

    test "false : boot_at_start true mais lifetime_scope != forever (incohérent G24-10)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{"boot_at_start" => true, "lifetime_scope" => "one-shot"})
             )
    end
  end

  describe "garde D-01 CRITIQUE — host_native exclu" do
    test "false : starfleet (boot_at_start false + host_native true) — JAMAIS fleet_spawner" do
      refute PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => false,
                 "lifetime_scope" => "forever",
                 "host_native" => true
               })
             )
    end

    test "false DÉFENSIF : host_native true MÊME si boot_at_start true (anti-violation D-01)" do
      refute PermanentBoot.boot_at_start?(
               cp(%{
                 "boot_at_start" => true,
                 "lifetime_scope" => "forever",
                 "host_native" => true
               })
             ),
             "host_native:true ne DOIT JAMAIS booter via fleet_spawner (D-01), " <>
               "même avec boot_at_start:true mal configuré"
    end
  end

  describe "robustesse entrées" do
    test "spec sans invocation → false" do
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

    test "accepte un spec map nu (string-keyed)" do
      assert PermanentBoot.boot_at_start?(%{
               "invocation" => %{"boot_at_start" => true, "lifetime_scope" => "forever"}
             })
    end
  end

  describe "select_permanent/1" do
    test "ne garde que les Type 1, exclut D-01 + workers" do
      profiles = [
        cp(%{"boot_at_start" => true, "lifetime_scope" => "forever", "host_native" => false}),
        cp(%{"boot_at_start" => false, "lifetime_scope" => "one-shot"}),
        cp(%{"boot_at_start" => true, "lifetime_scope" => "forever", "host_native" => true})
      ]

      assert [%Fleet.CapProfile{spec: %{"invocation" => %{"host_native" => false}}}] =
               PermanentBoot.select_permanent(profiles)
    end

    test "liste vide → []" do
      assert PermanentBoot.select_permanent([]) == []
    end
  end

  describe "boot_permanent_pods/1 (seams injectés — déterministe)" do
    @describetag :tmp_dir
    setup %{tmp_dir: dir} do
      for f <- ~w(architect-interactive.yaml engineer.yaml starfleet.yaml notes.txt) do
        File.write!(Path.join(dir, f), "x")
      end

      {:ok, dir: dir}
    end

    defp loader_for do
      fn
        "architect-interactive" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "architect-interactive"},
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

        "starfleet" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "starfleet"},
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

    test "spawn UNIQUEMENT architect-interactive (engineer worker + starfleet D-01 exclus)",
         %{dir: dir} do
      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:spawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      writer = fn pod_id, st ->
        send(parent, {:state, pod_id, st})
        :ok
      end

      assert {:ok, [pid_arch]} =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner,
                 state_writer: writer
               )

      assert pid_arch =~ ~r/^permanent-architect-interactive-/
      assert_received {:spawned, "architect-interactive", ^pid_arch}
      assert_received {:state, ^pid_arch, %{cap_profile_name: "architect-interactive"}}
      refute_received {:spawned, "engineer", _}
      refute_received {:spawned, "starfleet", _}
    end

    test "succès partiel : loader {:error} sur un rôle → skip, autres OK", %{dir: dir} do
      loader = fn
        "architect-interactive" -> loader_for().("architect-interactive")
        _ -> {:error, :invalid_schema}
      end

      assert {:ok, [_]} =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader,
                 spawner: fn _cp, _t, _o -> {:ok, self()} end,
                 state_writer: fn _i, _s -> :ok end
               )
    end

    test "succès partiel : spawner {:error} → pod_id omis", %{dir: dir} do
      assert {:ok, []} =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: fn _cp, _t, _o -> {:error, :launch_failed} end,
                 state_writer: fn _i, _s -> :ok end
               )
    end

    test "répertoire illisible → {:error,{:cap_profiles_dir_unreadable,_}}" do
      assert {:error, {:cap_profiles_dir_unreadable, _}} =
               PermanentBoot.boot_permanent_pods(cap_profiles_dir: "/nonexistent/dir/x")
    end
  end

  describe "conformance canon RÉEL — boot_at_start? sur cap-profiles in-repo" do
    # R0.8-brick5 : canon réabsorbé in-repo (R0.7) à `apps/fleet_capprofile/
    # priv/canon/cap-profiles/`. Plus de path doctrine `05_data-canon/...`
    # en dur (inexistant en standard install). Pattern identique brick1
    # MonkTest (resolve via Application.app_dir).
    @canon_dir Application.app_dir(:fleet_capprofile, "priv/canon/cap-profiles")

    defp canon_spec(name) do
      @canon_dir
      |> Path.join("#{name}.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.get("spec")
    end

    test "architect-interactive.yaml (canon réel) → boot_at_start? TRUE (Type 1)" do
      assert PermanentBoot.boot_at_start?(canon_spec("architect-interactive"))
    end

    test "starfleet.yaml (canon réel) → boot_at_start? FALSE (D-01 host_native préservé)" do
      refute PermanentBoot.boot_at_start?(canon_spec("starfleet")),
             "starfleet canon NE DOIT JAMAIS booter via fleet_spawner (D-01 host_native:true)"
    end

    test "engineer.yaml (canon réel) → boot_at_start? FALSE (worker one-shot)" do
      refute PermanentBoot.boot_at_start?(canon_spec("engineer"))
    end

    test "select_permanent sur les 7 cap-profiles canon → architect-interactive seul" do
      profiles =
        ~w(architect-interactive consultant engineer gatekeeper qualifier reviewer starfleet)
        |> Enum.map(fn n ->
          %Fleet.CapProfile{
            kind: "CapabilityProfile",
            metadata: %{"name" => n},
            spec: canon_spec(n)
          }
        end)

      selected = PermanentBoot.select_permanent(profiles)
      assert [%Fleet.CapProfile{metadata: %{"name" => "architect-interactive"}}] = selected
    end
  end

  describe "auto_boot_enabled?/0 — gate config (défaut OFF, umbrella stable)" do
    test "défaut false (non configuré : OFF en test/dev)" do
      refute PermanentBoot.auto_boot_enabled?()
    end

    test "true uniquement si :boot_permanent_at_start == true" do
      Application.put_env(:fleet_spawner, :boot_permanent_at_start, true)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :boot_permanent_at_start) end)
      assert PermanentBoot.auto_boot_enabled?()

      Application.put_env(:fleet_spawner, :boot_permanent_at_start, "yes")
      refute PermanentBoot.auto_boot_enabled?()
    end
  end
end
