defmodule Fleet.Spawner.PermanentBootTest do
  @moduledoc """
  Lot 3 inc1 — `Fleet.Spawner.PermanentBoot.boot_at_start?/1` garde D-01
  CRITIQUE (DN ring1/permanent-pods-boot.md). Pur, string-keyed
  (anti-M1 : pseudo-code DN atom-keys = illustratif).

  `async: false` : le describe `auto_boot_enabled?/0` mute la config Application
  globale (`:boot_permanent_at_start`) via `put_env` — couplage config runtime
  inhérent au prédicat, séquentialiser évite la race inter-module (BL-028).
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
    test "true : boot_at_start true + forever + host_native false (architect)" do
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
      # L'énumérateur (`CapProfile.list`) résout par `metadata.name` → fixtures yaml portant le name
      # (l'identité indexable). Le contenu COMPLET vient du loader injecté (`loader_for`). `notes.txt`
      # = non-.yaml, ignoré par le scan.
      for name <- ~w(architect engineer starfleet) do
        File.write!(Path.join(dir, "#{name}.yaml"), "metadata:\n  name: #{name}\n")
      end

      File.write!(Path.join(dir, "notes.txt"), "x")

      {:ok, dir: dir}
    end

    defp loader_for do
      fn
        "architect" ->
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "architect"},
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

    test "spawn UNIQUEMENT architect (engineer worker + starfleet D-01 exclus)",
         %{dir: dir} do
      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:spawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      # G9 : le boot rend la LISTE DES RÉSULTATS (safe_boot du BootOrchestrator la classe).
      assert [{:ok, pid_arch}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )

      # BL-055 : pod_id permanent DÉTERMINISTE (plus de `-<os_time>`) → idempotent.
      assert pid_arch == "permanent-architect"
      assert_received {:spawned, "architect", ^pid_arch}
      refute_received {:spawned, "engineer", _}
      refute_received {:spawned, "starfleet", _}
    end

    test "BL-055 : permanent déjà vivant ({:already_started}) → no-op idempotent (pod_id conservé)",
         %{dir: dir} do
      # id déterministe → un re-boot retombe sur `permanent-architect` ; si le pod tourne déjà,
      # spawn_pod rend {:already_started} → ce n'est PAS une erreur, le pod_id est conservé.
      spawner = fn _cp, _tid, _o -> {:error, {:already_started, self()}} end

      assert [{:ok, "permanent-architect"}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: spawner
               )
    end

    test "F-052 : load {:error} sur un rôle → fail-loud (deploy cassé, plus de skip silencieux)",
         %{dir: dir} do
      # Avant (doctrine « succès partiel ») : engineer/starfleet invalides étaient skippés, architect
      # bootait → {:ok, [arch]}. Révision crash-boot : un profil non chargeable = artefact cassé →
      # on propage. `list_roles` rend les rôles triés → engineer est le 1er à échouer (architect OK).
      loader = fn
        "architect" -> loader_for().("architect")
        _ -> {:error, :invalid_schema}
      end

      assert {:error, {:cap_profile_load_failed, "engineer", :invalid_schema}} =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader,
                 spawner: fn _cp, _t, _o -> {:ok, self()} end
               )
    end

    test "G9 boot HONNÊTE : spawner {:error} → l'échec est RENDU nommé, plus jamais filtré", %{
      dir: dir
    } do
      # AVANT (bug G9) : {:ok, []} — l'échec du spawn architect était avalé (reject nil) → le
      # BootOrchestrator émettait fleet.boot_complete MENTEUR. MAINTENANT : l'échec est dans la
      # liste des résultats, nommé (role + reason) → safe_boot le classe → fleet.boot_partial.
      assert [{:error, {"architect", :launch_failed}}] =
               PermanentBoot.boot_permanent_pods(
                 cap_profiles_dir: dir,
                 loader: loader_for(),
                 spawner: fn _cp, _t, _o -> {:error, :launch_failed} end
               )
    end

    test "G5 respawn/2 : re-spawn d'UN permanent via le chemin de boot (idempotent)", %{dir: _dir} do
      parent = self()

      spawner = fn %Fleet.CapProfile{metadata: %{"name" => n}}, tid, _o ->
        send(parent, {:respawned, n, tid})
        {:ok, spawn(fn -> :ok end)}
      end

      assert {:ok, "permanent-architect"} =
               PermanentBoot.respawn("architect", loader: loader_for(), spawner: spawner)

      assert_received {:respawned, "architect", "permanent-architect"}
    end

    test "G5 respawn/2 : garde-fou — un rôle NON-permanent est refusé fail-loud" do
      # engineer (boot_at_start: false) : même si un pod_id `permanent-engineer` forgé le demandait,
      # respawn refuse — un worker one-shot n'a rien à faire dans le cycle permanent.
      assert {:error, {"engineer", :not_a_permanent}} =
               PermanentBoot.respawn("engineer",
                 loader: loader_for(),
                 spawner: fn _c, _t, _o -> flunk("ne doit pas spawner") end
               )
    end

    test "G5 respawn/2 : cap-profile illisible → {:error, {role, {:cap_profile_load_failed, _}}}" do
      assert {:error, {"architect", {:cap_profile_load_failed, :corrupt}}} =
               PermanentBoot.respawn("architect",
                 loader: fn _ -> {:error, :corrupt} end,
                 spawner: fn _c, _t, _o -> flunk("ne doit pas spawner") end
               )
    end

    test "répertoire illisible → {:error,{:cap_profiles_dir_unreadable,_}}" do
      assert {:error, {:cap_profiles_dir_unreadable, _}} =
               PermanentBoot.boot_permanent_pods(cap_profiles_dir: "/nonexistent/dir/x")
    end
  end

  describe "conformance canon RÉEL — boot_at_start? sur cap-profiles in-repo" do
    # R0.8-brick5 : canon réabsorbé in-repo (R0.7) à `apps/fleet_cap_profile/
    # priv/canon/cap-profiles/`. Plus de path doctrine `05_data-canon/...`
    # en dur (inexistant en standard install). Pattern identique brick1
    # MonkTest (resolve via Application.app_dir).
    @canon_dir Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles")

    defp canon_spec(name) do
      @canon_dir
      |> Path.join("#{name}.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.get("spec")
    end

    test "architect.yaml (canon réel) → boot_at_start? TRUE (Type 1)" do
      assert PermanentBoot.boot_at_start?(canon_spec("architect"))
    end

    test "starfleet.yaml (canon réel) → boot_at_start? FALSE (D-01 host_native préservé)" do
      refute PermanentBoot.boot_at_start?(canon_spec("starfleet")),
             "starfleet canon NE DOIT JAMAIS booter via fleet_spawner (D-01 host_native:true)"
    end

    test "engineer.yaml (canon réel) → boot_at_start? FALSE (worker one-shot)" do
      refute PermanentBoot.boot_at_start?(canon_spec("engineer"))
    end

    test "select_permanent sur les 7 cap-profiles canon → architect seul" do
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
      assert [%Fleet.CapProfile{metadata: %{"name" => "architect"}}] = selected
    end
  end

  # BL-028 (R7→clos) : `auto_boot_enabled?/0` EST le gate canon du boot des pods
  # permanents (consulté par BootOrchestrator, autorité unique depuis F-14).
  # Défaut **true** (DN lcars-fleet_service §391) ; `false` désactive.
  describe "auto_boot_enabled?/0 — gate canon boot pods permanents (défaut true)" do
    test "défaut true (non configuré) — boote par défaut, canon DN" do
      assert PermanentBoot.auto_boot_enabled?()
    end

    test "false seulement si :boot_permanent_at_start mis explicitement à false" do
      Application.put_env(:fleet_spawner, :boot_permanent_at_start, false)
      on_exit(fn -> Application.delete_env(:fleet_spawner, :boot_permanent_at_start) end)
      refute PermanentBoot.auto_boot_enabled?()

      Application.put_env(:fleet_spawner, :boot_permanent_at_start, true)
      assert PermanentBoot.auto_boot_enabled?()

      # Seul le booléen `true` active (pas une string "yes").
      Application.put_env(:fleet_spawner, :boot_permanent_at_start, "yes")
      refute PermanentBoot.auto_boot_enabled?()
    end
  end
end
