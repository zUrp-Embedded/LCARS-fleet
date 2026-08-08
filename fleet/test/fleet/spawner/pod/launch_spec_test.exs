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
    test "a mount with a newline (injection) → REFUSAL (raise), no drop-and-launch" do
      # DR-021: an injecting mount is an INVALID state (attack-shaped). Dropping it and continuing the
      # launch would be downstream repair of an invalid profile. LOUD refusal → the projection fails
      # (the raise is caught by LaunchEnv.build/4 → {:error, {:launch_env_unresolved, _}}, no launch).
      cap = cap_with_mounts([%{"mode" => "ro", "path" => "/legit\nrw:/etc/shadow"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*injection/s, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end

    test "a `\\r` (CR) in a mount → REFUSAL too (same injection)" do
      cap = cap_with_mounts([%{"mode" => "rw\rro", "path" => "/x"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL/, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end

    test "a NORMAL mount is serialized (mode:path)" do
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/home/project"}])
      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      assert env =~ "rw:/home/project"
    end

    test "a mount with an OUT-OF-ENUM mode (typo) → REFUSAL (raise), no soft fallback to `ro`" do
      # DR-021: `mode` is a SECURITY property (RO vs RW = out-of-sandbox writes). A nil/typo mode
      # (`"RW"`) present-but-invalid = schema-bypassed profile → refusal, never normalized to `ro`
      # (normalizing a typoed RW into RO silently changes the meaning of an invalid profile). The
      # schema already bounds `mode ∈ {ro,rw}` at LOAD; this check is the eval boundary. Twin of
      # `permission_mode`.
      cap = cap_with_mounts([%{"mode" => "RW", "path" => "/x"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*mount mode/s, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end
  end

  describe "pod_mounts_env/3 — the COMPOSITION, which nothing held" do
    # Le monde d'un pod a CINQ sources — system, cap-profile, opts de spawn, project-ops,
    # code-reference — concatenees puis passees a `Enum.uniq_by/2`. Chaque source avait ses tests ;
    # l'ASSEMBLAGE n'en avait aucun, alors qu'il porte une garantie ecrite (« Earlier entries win on
    # duplicate paths ») et que cette garantie decide un MODE. Or le mode est la propriete de
    # securite de ce module — les trois refus ci-dessus existent pour lui, et aucun ne regarde le
    # cas ou deux sources reclament le meme chemin.
    #
    # `uniq_by` garde la PREMIERE occurrence : l'ordre de concatenation n'est donc pas un detail de
    # style, c'est la table de priorite, et elle n'est ecrite nulle part ailleurs que dans l'ordre
    # des `++`.
    test "deux sources sur le MEME chemin : la premiere gagne, et c'est son MODE qui sort" do
      # system (`/opt/bin`, ro) est concatene AVANT le cap-profile. Le profil reclame `rw` sur le
      # meme chemin : il perd. Un `uniq_by` qui garderait la derniere occurrence rendrait ici un
      # `rw` hors sandbox sans qu'aucun des refus de ce module ne se declenche — ils valident la
      # FORME d'un mount, jamais lequel des deux survit.
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/opt/bin"}])
      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/bin/claude_launch.sh")

      assert env =~ "ro:/opt/bin"
      refute env =~ "rw:/opt/bin"
    end

    test "cap-profile AVANT opts de spawn : le catalogue gagne sur la demande de spawn" do
      # L'ordre qui compte le jour ou un appelant de spawn passe un `mounts:` chevauchant le
      # catalogue. Le catalogue est la declaration statique auditee ; la demande de spawn est
      # dynamique. Elle ne relache pas un mode que le catalogue a serre.
      cap = cap_with_mounts([%{"mode" => "ro", "path" => "/srv/shared"}])

      env =
        LaunchSpec.pod_mounts_env(
          cap,
          [mounts: [%{"mode" => "rw", "path" => "/srv/shared"}]],
          "/usr/local/bin/claude_launch.sh"
        )

      assert env =~ "ro:/srv/shared"
      refute env =~ "rw:/srv/shared"
    end

    # ❌ PAS de test pour la collision REELLE de l'architecte — `opts[:mounts]` en `rw` sur
    # `<work_root>/<project>` contre le `ro` que `project_ops_mount` pose sur le meme chemin, ou
    # c'est l'ordre des `++` qui lui conserve son droit d'ecriture. Deux raisons, dans cet ordre :
    # `Fleet.Layout.work_root/0` est une constante de compilation, donc le forcer demanderait un
    # seam de plus dans `pod_mounts_env/3` ; et `project_ops_mount` est RETIRE par le chantier trois
    # faces. Epingler ici un mecanisme programme pour disparaitre ferait un test a jeter avec lui.
    # La propriete d'ordre qui SURVIT a ce retrait est celle des deux tests ci-dessus.
  end

  describe "project_ops_path/3 — the world of ITS project (RO, scoped), neither nothing nor everything" do
    # The sanctuary projects ITS project's work/ops (context/doctrine) so the worker KNOWS instead of
    # guessing the surroundings — not the whole `/home/projects.work` (other projects' world = noise +
    # over-exposure), not nothing (starvation → it guesses = the poison). `work_root` seam = testable
    # (the real one is hardcoded).
    test "no project (:project_slug absent) → nil: nothing to project" do
      assert LaunchSpec.project_ops_path([], cap_with_mounts([]), "/tmp") == nil
    end

    test "project but work/ops ABSENT → nil (the STRICT ro-bind launcher would crash on a missing source)" do
      assert LaunchSpec.project_ops_path(
               [rc_name: "ghost_test", project_slug: "ghost"],
               cap_with_mounts([]),
               "/tmp/nexiste-pas-42"
             ) ==
               nil
    end

    @tag :tmp_dir
    test "project + work/ops present → the scoped path <work_root>/<project> (ITS world)", %{
      tmp_dir: tmp
    } do
      File.mkdir_p!(Path.join(tmp, "myproj"))

      assert LaunchSpec.project_ops_path(
               [rc_name: "myproj_test", project_slug: "myproj"],
               cap_with_mounts([]),
               tmp
             ) ==
               Path.join(tmp, "myproj")
    end
  end

  describe "code_reference_path/3 — the OPPOSITE face as RO reference" do
    # A doc-face pod reads the code it documents; a code-face pod gets nothing new (its workspace
    # IS the code). The face comes off the project map's base_branch — threaded, never re-derived.
    # NEVER the ops face: no card can declare it, so no producer clone ever sits on that branch.
    defp ops_opts(project_extra \\ %{}) do
      [
        rc_name: "myproj_test",
        project_slug: "myproj",
        project:
          Map.merge(
            %{"repo_path" => "http://f/x.git", "base_branch" => "work/doc"},
            project_extra
          )
      ]
    end

    @tag :tmp_dir
    test "doc-face pod + code worktree present → <projects_root>/<project>", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "myproj"))

      assert LaunchSpec.code_reference_path(ops_opts(), cap_with_mounts([]), tmp) ==
               Path.join(tmp, "myproj")
    end

    @tag :tmp_dir
    test "code-face pod → nil (its workspace IS the code; work-ops was already its reference)", %{
      tmp_dir: tmp
    } do
      File.mkdir_p!(Path.join(tmp, "myproj"))

      code_opts = [
        rc_name: "myproj_test",
        project_slug: "myproj",
        project: %{"repo_path" => "http://f/x.git", "base_branch" => "main"}
      ]

      assert LaunchSpec.code_reference_path(code_opts, cap_with_mounts([]), tmp) == nil
    end

    @tag :tmp_dir
    test "a FEATURE branch is not the ops face → nil (judge cloning an ops PR head: code-face treatment)",
         %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "myproj"))

      judge_opts = [
        rc_name: "myproj_test",
        project_slug: "myproj",
        project: %{"repo_path" => "http://f/x.git", "base_branch" => "lcars/issue-3-scribe"}
      ]

      assert LaunchSpec.code_reference_path(judge_opts, cap_with_mounts([]), tmp) == nil
    end

    test "ops-face pod but code worktree ABSENT → nil (the STRICT ro-bind would crash the spawn)" do
      assert LaunchSpec.code_reference_path(
               ops_opts(),
               cap_with_mounts([]),
               "/tmp/nexiste-pas-43"
             ) ==
               nil
    end
  end

  describe "skills_paths_env/1 — the skills delivery rail (BL-6-22)" do
    test "newline-delimited name:path entries — the LCARS_POD_MOUNTS pattern, space-safe" do
      # A root WITH a space is the exact case a space-separated format would shatter on.
      paths = ["/opt/my catalogue/skills/canon/card-revision", "/opt/skills/deep-dive"]

      assert %{"LCARS_SKILLS_PATHS" => env} = LaunchSpec.skills_paths_env(paths)

      assert env ==
               "card-revision:/opt/my catalogue/skills/canon/card-revision\n" <>
                 "deep-dive:/opt/skills/deep-dive"
    end

    test "empty list → no var at all (no bind loop launcher-side)" do
      assert LaunchSpec.skills_paths_env([]) == %{}
    end

    test "a newline in a path REFUSES the projection (DR-021 — never drop-and-launch)" do
      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*LCARS_SKILLS_PATHS/s, fn ->
        LaunchSpec.skills_paths_env(["/tmp/skills/ok", "/tmp/evil\n--rw-bind /etc"])
      end
    end
  end

  describe "permission_mode/1 — bounded to the CLI enum (R1-28)" do
    defp cap_with_permission_mode(mode) do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "test", "containment" => "bwrap"},
        spec: %{"invocation" => %{"permission_mode" => mode}}
      }
    end

    test "VALID enum modes are kept" do
      for mode <- ~w(default acceptEdits bypassPermissions plan) do
        assert LaunchSpec.permission_mode(cap_with_permission_mode(mode)) == mode
      end
    end

    test "an UNKNOWN mode (forged security setting) → REFUSAL (raise), no \"default\" fallback" do
      # DR-021: normalizing an invalid permission_mode into "default" silently changes the meaning of a
      # forged security profile (a typoed "bypassPermissions" would become enforced, or the reverse).
      # Present-but-out-of-enum → LOUD refusal; the projection fails (raise caught by LaunchEnv.build/4).
      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*permission_mode/s, fn ->
        LaunchSpec.permission_mode(cap_with_permission_mode("yolo-bypass-everything"))
      end
    end

    test "absent → default (legitimate schema default: unspecified = enforced, NOT an invalid value)" do
      cap = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}
      assert LaunchSpec.permission_mode(cap) == "default"
    end
  end
end
