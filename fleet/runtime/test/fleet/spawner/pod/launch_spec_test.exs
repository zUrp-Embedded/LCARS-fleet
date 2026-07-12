defmodule Fleet.Spawner.Pod.LaunchSpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Spawner.Pod.LaunchSpec

  defp cap_with_mounts(mounts) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap", "mounts" => mounts},
      spec: %{}
    }
  end

  describe "pod_mounts_env/2 — anti-injection LCARS_POD_MOUNTS (R1-27)" do
    test "un mount avec newline (injection) est DROPPÉ + loggé, pas sérialisé" do
      cap = cap_with_mounts([%{"mode" => "ro", "path" => "/legit\nrw:/etc/shadow"}])

      {env, log} = with_log(fn -> LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh") end)

      refute env =~ "/etc/shadow",
             "le mount injecté via newline ne doit PAS apparaître dans LCARS_POD_MOUNTS"

      assert log =~ "DROPPED"
    end

    test "un `\\r` (CR) dans un mount est aussi traité comme injection" do
      cap = cap_with_mounts([%{"mode" => "rw\rro", "path" => "/x"}])
      {env, _log} = with_log(fn -> LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh") end)
      refute env =~ "/x"
    end

    test "un mount NORMAL est sérialisé (mode:path)" do
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/home/project"}])
      env = LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh")
      assert env =~ "rw:/home/project"
    end

    test "un mount avec mode HORS-ENUM (typo) est borné à `ro` (safe), pas sérialisé brut" do
      # Repli mou #5 : `mode` sérialisé BRUT dans LCARS_POD_MOUNTS. Un mode nil/typo (`"RW"`) déléguait la
      # sémantique RW/RO au parse de bwrap_launch.sh (RW hors-sandbox s'il le traite permissif). Le schéma
      # borne déjà `mode ∈ {ro,rw}` au LOAD (upstream) ; ici on borne AUSSI au eval (défense-en-profondeur
      # pour un struct schéma-bypassé) → mode inconnu = `ro` (côté RESTRICTIF), jamais brut. Jumeau de
      # `permission_mode`.
      cap = cap_with_mounts([%{"mode" => "RW", "path" => "/x"}])
      {env, log} = with_log(fn -> LaunchSpec.pod_mounts_env(cap, "/opt/claude_launch.sh") end)
      assert env =~ "ro:/x"
      refute env =~ "RW:/x"
      assert log =~ "unknown mount mode"
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

    test "un mode INCONNU (setting sécurité forgé) → fallback \"default\" (safe) + warning" do
      {mode, log} =
        with_log(fn ->
          LaunchSpec.permission_mode(cap_with_permission_mode("yolo-bypass-everything"))
        end)

      assert mode == "default"
      assert log =~ "unknown permission_mode"
    end

    test "absent → default" do
      cap = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}
      assert LaunchSpec.permission_mode(cap) == "default"
    end
  end
end
