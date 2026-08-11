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
    # Le monde d'un pod a QUATRE sources — system, cap-profile, opts de spawn, autre-face —
    # concatenees puis passees a `Enum.uniq_by/2`. Chaque source avait ses tests ;
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

    test "AUCUN montage n'est derive de la racine ops — le registre n'est pas le monde d'un pod" do
      # LA PROPRIETE DU SEVRAGE, et c'est une ABSENCE, donc elle a besoin d'un garde explicite : une
      # absence ne rougit jamais toute seule. Chaque pod projet portait un `--ro-bind` de
      # `<ops_root>/<projet>` — briefs, gate-briefs, verdicts, provenance : le registre que le
      # runtime tient sur le travail, y compris celui du pod qui le lisait. Il etait la pour qu'UN
      # role lise UN fichier, et ce fichier voyage desormais en texte dans le work item.
      #
      # Re-ajouter une source derivee de la racine ops fait rougir cette ligne. C'est le seul
      # endroit ou ca rougit : le reste du module ne regarde que la forme des mounts.
      opts = [
        rc_name: "myproj_test",
        project_slug: "myproj",
        project: %{"repo_path" => "http://f/x.git", "base_branch" => "main"}
      ]

      env =
        LaunchSpec.pod_mounts_env(cap_with_mounts([]), opts, "/usr/local/bin/claude_launch.sh")

      refute env =~ Fleet.Layout.ops_root(),
             "un pod producteur ne monte pas l'arbre ou son propre travail est juge"
    end

    # ❌ PAS de test pour la collision RW/RO de l'architecte sur la face ops : le mecanisme qui la
    # produisait — un `project_ops_mount` pose APRES `opts[:mounts]` sur le meme chemin — n'existe
    # plus. L'architecte obtient ops par son `mounts:` explicite et rien ne le lui dispute, donc il
    # n'y a plus de precedence a epingler la. Celle qui reste est celle des deux tests plus haut.
  end

  describe "other_face_reference_path/3 — the OTHER production face, read-only" do
    # WHAT REPLACED THE OPS MOUNT. Every project pod used to carry a read-only bind of the
    # runtime's record (`<ops_root>/<project>`): briefs, gate-briefs, verdicts, provenance. It
    # was there so ONE role could read ONE file out of it, and the brief and the judging criterion
    # now travel as text. What a producer actually needs is the OTHER production face — the code it
    # documents, or the documentation it implements against — and nothing else.
    #
    # The face comes off the project map's `base_branch`, threaded from the card, never re-derived.
    defp face_opts(base_branch) do
      [
        rc_name: "myproj_test",
        project_slug: "myproj",
        project: %{"repo_path" => "http://f/x.git", "base_branch" => base_branch}
      ]
    end

    defp roots(tmp), do: %{"code" => Path.join(tmp, "code"), "workshop" => Path.join(tmp, "doc")}

    @tag :tmp_dir
    test "a DOC producer gets the code tree", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "code", "myproj"]))
      File.mkdir_p!(Path.join([tmp, "doc", "myproj"]))

      assert LaunchSpec.other_face_reference_path(
               face_opts("workshop"),
               cap_with_mounts([]),
               roots(tmp)
             ) == Path.join([tmp, "code", "myproj"])
    end

    @tag :tmp_dir
    test "a CODE producer gets the doc tree — the symmetry, which did not exist before", %{
      tmp_dir: tmp
    } do
      # The old shape granted the reference in ONE direction and gave everyone the ops tree in the
      # other. An engineer had the ledger and not the documentation it implements against; now it
      # has the documentation and not the ledger.
      File.mkdir_p!(Path.join([tmp, "code", "myproj"]))
      File.mkdir_p!(Path.join([tmp, "doc", "myproj"]))

      assert LaunchSpec.other_face_reference_path(
               face_opts("main"),
               cap_with_mounts([]),
               roots(tmp)
             ) == Path.join([tmp, "doc", "myproj"])
    end

    @tag :tmp_dir
    test "a FEATURE branch is not a face → nil (a judge clones the producer's head)", %{
      tmp_dir: tmp
    } do
      File.mkdir_p!(Path.join([tmp, "code", "myproj"]))
      File.mkdir_p!(Path.join([tmp, "doc", "myproj"]))

      assert LaunchSpec.other_face_reference_path(
               face_opts("lcars/issue-3-scribe"),
               cap_with_mounts([]),
               roots(tmp)
             ) == nil
    end

    @tag :tmp_dir
    test "the OPS branch is not a production face → nil, and no clause says so", %{tmp_dir: tmp} do
      # `face_of/1` answers "ops" here, and `other_face/1` has no clause for it — the guard is the
      # `when face in ["code", "doc"]`, which is the same list the card enum allows. A pod on
      # ops is unreachable by construction; this pins that the reference path agrees rather
      # than inventing a direction for it.
      File.mkdir_p!(Path.join([tmp, "code", "myproj"]))

      assert LaunchSpec.other_face_reference_path(
               face_opts("ops"),
               cap_with_mounts([]),
               roots(tmp)
             ) == nil
    end

    test "no project (:project_slug absent) → nil: nothing to reference" do
      assert LaunchSpec.other_face_reference_path(
               [project: %{"base_branch" => "main"}],
               cap_with_mounts([]),
               %{"code" => "/tmp", "workshop" => "/tmp"}
             ) == nil
    end

    test "the other face's worktree ABSENT → nil (the STRICT ro-bind would crash the spawn)" do
      assert LaunchSpec.other_face_reference_path(
               face_opts("main"),
               cap_with_mounts([]),
               %{"code" => "/tmp/nexiste-pas-43", "workshop" => "/tmp/nexiste-pas-44"}
             ) == nil
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

  describe "pin_reference_face/2 — the reference stops moving under the pod" do
    @describetag :tmp_dir

    defp face_repo(tmp) do
      src = Path.join(tmp, "workshop-face")
      File.mkdir_p!(src)
      {_, 0} = System.cmd("git", ["init", "-q", src], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", src, "config", "user.email", "h@lcars.local"])
      {_, 0} = System.cmd("git", ["-C", src, "config", "user.name", "H"])
      File.mkdir_p!(Path.join(src, "refs"))
      File.write!(Path.join([src, "refs", "ina219.txt"]), "0x40 shunt")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", src, "commit", "-q", "-m", "datasheet"])
      src
    end

    test "the copy carries the content and NO back-reference to its source", %{tmp_dir: tmp} do
      src = face_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:ok, pinned} = LaunchSpec.pin_reference_face(src, pod_dir)
      assert File.read!(Path.join([pinned, "refs", "ina219.txt"])) == "0x40 shunt"

      # No `.git`: a pointer back into the source is exactly what must not survive the source.
      refute File.exists?(Path.join(pinned, ".git"))
      # And the tarball is not left behind in the pod's world.
      assert Path.wildcard(Path.join(pod_dir, "*.tar")) == []
    end

    test "the pinned reference SURVIVES its source being removed mid-flight", %{tmp_dir: tmp} do
      # This is the whole point. `delete_project` nukes the faces without consulting running pods;
      # a live `--ro-bind` then became a dangling mount the pod read as an empty tree, silently.
      src = face_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)
      {:ok, pinned} = LaunchSpec.pin_reference_face(src, pod_dir)

      File.rm_rf!(src)

      assert File.read!(Path.join([pinned, "refs", "ina219.txt"])) == "0x40 shunt"
    end

    test "a write in the source AFTER the pin does not reach the pod", %{tmp_dir: tmp} do
      # The human and the architect write in that face continuously, and `WorktreeSync` rebases it
      # after each merge. Live, a producer could compose against a state that never existed whole.
      src = face_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)
      {:ok, pinned} = LaunchSpec.pin_reference_face(src, pod_dir)

      File.write!(Path.join([src, "refs", "ina219.txt"]), "0x41 shunt")

      assert File.read!(Path.join([pinned, "refs", "ina219.txt"])) == "0x40 shunt"
    end

    test "a source that is not its own repo REFUSES — `git -C` walks UP", %{tmp_dir: tmp} do
      # Not a hypothetical: these fixtures live under the LCARS checkout, so without the toplevel
      # check the first run archived the whole runtime into the pod and reported success.
      plain = Path.join(tmp, "not-a-repo")
      File.mkdir_p!(plain)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:error, {:not_a_face_repo, ^plain, _}} =
               LaunchSpec.pin_reference_face(plain, pod_dir)

      refute File.exists?(Path.join([pod_dir, "ref", "not-a-repo"]))
    end
  end

  describe "mounts_env — the translated mount (`mode:src:dst`)" do
    test "src and dst travel together when they differ, and the guard covers dst" do
      cap =
        cap_with_mounts([
          %{"mode" => "ro", "path" => "/pod/ref/x", "dst" => "/home/projects.workshop/x"}
        ])

      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      assert env =~ "ro:/pod/ref/x:/home/projects.workshop/x"

      injecting =
        cap_with_mounts([%{"mode" => "ro", "path" => "/ok", "dst" => "/x\nrw:/etc/shadow"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL/, fn ->
        LaunchSpec.pod_mounts_env(injecting, [], "/opt/claude_launch.sh")
      end
    end

    test "an ordinary mount stays two fields — no translation to check where there is none" do
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/home/project"}])
      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      assert env =~ "rw:/home/project"
      refute env =~ "rw:/home/project:"
    end
  end
end
