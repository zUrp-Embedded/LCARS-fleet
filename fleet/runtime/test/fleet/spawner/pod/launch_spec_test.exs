defmodule Fleet.Spawner.Pod.LaunchSpecTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.LaunchSpec

  defp cap_with_mounts(mounts) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap", "mounts" => mounts},
      spec: %{}
    }
  end

  describe "pod_mounts_env/2 — anti-injection LCARS_POD_MOUNTS (R1-27 / DR-021)" do
    test "un mount avec newline (injection) → REFUS (raise), pas de drop-and-launch" do
      # DR-021 : un mount injectant est un état INVALIDE (attaque-shaped). Avant : droppé + launch continue
      # (réparation aval d'un profil invalide). Désormais : refus LOUD → la projection échoue (le raise est
      # capté par LaunchEnv.build/4 → {:error, {:launch_env_unresolved, _}}, aucun launch).
      cap = cap_with_mounts([%{"mode" => "ro", "path" => "/legit\nrw:/etc/shadow"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*injection/s, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end

    test "un `\\r` (CR) dans un mount → REFUS aussi (même injection)" do
      cap = cap_with_mounts([%{"mode" => "rw\rro", "path" => "/x"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL/, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end

    test "un mount NORMAL est sérialisé (mode:path)" do
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/home/project"}])
      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      assert env =~ "rw:/home/project"
    end

    test "un mount avec mode HORS-ENUM (typo) → REFUS (raise), pas de repli mou vers `ro`" do
      # DR-021 : `mode` est une propriété de SÉCURITÉ (RO vs RW = écriture hors-sandbox). Un mode nil/typo
      # (`"RW"`) présent-mais-invalide = profil schéma-bypassé → refus, jamais normalisé à `ro` (normaliser
      # un RW typoé en RO change silencieusement le sens d'un profil invalide). Le schéma borne déjà
      # `mode ∈ {ro,rw}` au LOAD ; ce check est la frontière eval. Jumeau de `permission_mode`.
      cap = cap_with_mounts([%{"mode" => "RW", "path" => "/x"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*mount mode/s, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end
  end

  describe "project_ops_path/3 — le monde de SON projet (RO, scopé), ni rien ni tout" do
    # Le sanctuaire projette le work/ops de SON projet (context/doctrine) pour que le worker SACHE au lieu de
    # deviner les à-côtés — pas `/home/projects.work` entier (le monde des autres = bruit + sur-exposition),
    # pas rien (famine → il devine = le poison). `work_root` seam = testable (le vrai est hardcodé).
    test "pas de projet (rc_name absent) → nil : rien à projeter" do
      assert LaunchSpec.project_ops_path([], cap_with_mounts([]), "/tmp") == nil
    end

    test "projet mais work/ops ABSENT → nil (le launcher ro-bind STRICT crasherait sur un source manquant)" do
      assert LaunchSpec.project_ops_path([rc_name: "ghost_test"], cap_with_mounts([]), "/tmp/nexiste-pas-42") ==
               nil
    end

    @tag :tmp_dir
    test "projet + work/ops présent → le chemin scopé <work_root>/<projet> (SON monde)", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "myproj"))

      assert LaunchSpec.project_ops_path([rc_name: "myproj_test"], cap_with_mounts([]), tmp) ==
               Path.join(tmp, "myproj")
    end
  end

  describe "permission_mode/1 — borné à l'enum CLI (R1-28)" do
    defp cap_with_permission_mode(mode) do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "test", "containment" => "bwrap"},
        spec: %{"invocation" => %{"permission_mode" => mode}}
      }
    end

    test "les modes VALIDES de l'enum sont conservés" do
      for mode <- ~w(default acceptEdits bypassPermissions plan) do
        assert LaunchSpec.permission_mode(cap_with_permission_mode(mode)) == mode
      end
    end

    test "un mode INCONNU (setting sécurité forgé) → REFUS (raise), pas de fallback \"default\"" do
      # DR-021 : normaliser un permission_mode invalide en "default" change silencieusement le sens d'un
      # profil de sécurité forgé (un "bypassPermissions" typoé deviendrait enforced, ou l'inverse). Présent-
      # mais-hors-enum → refus LOUD ; la projection échoue (raise capté par LaunchEnv.build/4).
      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*permission_mode/s, fn ->
        LaunchSpec.permission_mode(cap_with_permission_mode("yolo-bypass-everything"))
      end
    end

    test "absent → default (défaut schéma légitime : non-spécifié = enforced, PAS une valeur invalide)" do
      cap = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}
      assert LaunchSpec.permission_mode(cap) == "default"
    end
  end
end
