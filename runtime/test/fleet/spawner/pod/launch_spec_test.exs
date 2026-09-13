defmodule Fleet.Spawner.Pod.LaunchSpecTest do
  # Serial: LCARS_STORE_ROOT is node-global, including during restoration.
  use ExUnit.Case, async: false

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
      # Malformed mount input must reject projection rather than silently alter the requested world.
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
      # This boundary also rejects profiles that bypassed schema validation.
      cap = cap_with_mounts([%{"mode" => "RW", "path" => "/x"}])

      assert_raise ArgumentError, ~r/SECURITY REFUSAL.*mount mode/s, fn ->
        LaunchSpec.pod_mounts_env(cap, [], "/opt/claude_launch.sh")
      end
    end
  end

  describe "pod_mounts_env/3 — the COMPOSITION, which nothing held" do
    # Deduplication selects a mode as well as a path; test priority across sources.
    test "deux sources sur le MEME chemin : la premiere gagne, et c'est son MODE qui sort" do
      # System mounts precede the profile, so its RW request cannot widen this RO source.
      cap = cap_with_mounts([%{"mode" => "rw", "path" => "/opt/bin"}])
      env = LaunchSpec.pod_mounts_env(cap, [], "/opt/bin/claude_launch.sh")

      assert env =~ "ro:/opt/bin"
      refute env =~ "rw:/opt/bin"
    end

    test "cap-profile AVANT opts de spawn : le catalogue gagne sur la demande de spawn" do
      # Profile mounts precede dynamic spawn requests on the same source path.
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
      # Producers receive briefs/criteria without the ops ledger used to judge their work.
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
  end

  describe "other_face_reference_path/3 — the OTHER production face, read-only" do
    # The project’s base_branch identifies the production face whose counterpart is needed.
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
      # The explicit production-face guard excludes ops even when face_of identifies it.
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
      paths = ["/opt/my catalogue/skills/card-revision", "/opt/skills/deep-dive"]

      assert %{"LCARS_SKILLS_PATHS" => env} = LaunchSpec.skills_paths_env(paths)

      assert env ==
               "card-revision:/opt/my catalogue/skills/card-revision\n" <>
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

      refute File.exists?(Path.join(pinned, ".git"))
      assert Path.wildcard(Path.join(pod_dir, "*.tar")) == []
    end

    test "the pinned reference SURVIVES its source being removed mid-flight", %{tmp_dir: tmp} do
      # A pinned copy must survive project deletion without relying on its source worktree.
      src = face_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)
      {:ok, pinned} = LaunchSpec.pin_reference_face(src, pod_dir)

      File.rm_rf!(src)

      assert File.read!(Path.join([pinned, "refs", "ina219.txt"])) == "0x40 shunt"
    end

    test "a write in the source AFTER the pin does not reach the pod", %{tmp_dir: tmp} do
      # Host edits and WorktreeSync rebases must not change the pod’s pinned reference.
      src = face_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)
      {:ok, pinned} = LaunchSpec.pin_reference_face(src, pod_dir)

      File.write!(Path.join([src, "refs", "ina219.txt"]), "0x41 shunt")

      assert File.read!(Path.join([pinned, "refs", "ina219.txt"])) == "0x40 shunt"
    end

    test "a source that is not its own repo REFUSES — `git -C` walks UP", %{tmp_dir: tmp} do
      # The fixture is inside this checkout; Git could otherwise archive the enclosing runtime.
      plain = Path.join(tmp, "not-a-repo")
      File.mkdir_p!(plain)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:error, {:not_a_face_repo, ^plain, _}} =
               LaunchSpec.pin_reference_face(plain, pod_dir)

      refute File.exists?(Path.join([pod_dir, "ref", "not-a-repo"]))
    end
  end

  describe "pin_object/4 — one file, one pinned version, nothing else" do
    @describetag :tmp_dir

    # Commit two versions of the brief and a neighboring file; return the first SHA.
    defp ops_repo(tmp) do
      src = Path.join(tmp, "ops-face")
      File.mkdir_p!(Path.join(src, "briefs"))
      {_, 0} = System.cmd("git", ["init", "-q", src], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", src, "config", "user.email", "h@lcars.local"])
      {_, 0} = System.cmd("git", ["-C", src, "config", "user.name", "H"])

      File.write!(Path.join([src, "briefs", "issue-3-engineer.md"]), "ORDER v1")
      File.write!(Path.join([src, "briefs", "issue-9-other.md"]), "someone else's order")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", src, "commit", "-q", "-m", "v1"])
      {sha, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"])

      File.write!(Path.join([src, "briefs", "issue-3-engineer.md"]), "ORDER v2")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", src, "commit", "-q", "-m", "v2"])

      {src, String.trim(sha)}
    end

    test "the pinned version travels, and the later one does NOT", %{tmp_dir: tmp} do
      {src, sha} = ops_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:ok, file} =
               LaunchSpec.pin_object(src, pod_dir, sha, "briefs/issue-3-engineer.md")

      assert File.read!(file) == "ORDER v1"
      refute File.read!(file) == "ORDER v2"
    end

    test "the path filter is airtight — no other ticket's file rides along", %{tmp_dir: tmp} do
      {src, sha} = ops_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      {:ok, file} = LaunchSpec.pin_object(src, pod_dir, sha, "briefs/issue-3-engineer.md")

      # The neighboring ticket exists at the same commit and must not enter this archive.
      root = Path.join(pod_dir, "obj")
      others = Path.wildcard(Path.join(root, "**/issue-9-other.md"))
      assert others == [], "the mount leaked another ticket's order: #{inspect(others)}"

      refute File.exists?(Path.join(Path.dirname(Path.dirname(file)), ".git"))
      assert Path.wildcard(Path.join(pod_dir, "*.tar")) == []
    end

    test "a non-commit-sha is REFUSED before any git runs", %{tmp_dir: tmp} do
      {src, _sha} = ops_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:error, {:not_a_commit_sha, "HEAD"}} =
               LaunchSpec.pin_object(src, pod_dir, "HEAD", "briefs/issue-3-engineer.md")
    end

    test "a path absent at the sha FAILS — never a silent empty mount", %{tmp_dir: tmp} do
      {src, sha} = ops_repo(tmp)
      pod_dir = Path.join(tmp, "pod")
      File.mkdir_p!(pod_dir)

      assert {:error, _} =
               LaunchSpec.pin_object(src, pod_dir, sha, "briefs/does-not-exist.md")
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

  describe "le magasin d'outillage — monte, et l'environnement qui le rend utilisable" do
    setup do
      root =
        Fleet.TestEnv.tmp_path("lcars-store-test")

      File.mkdir_p!(Path.join(root, "state/env.d"))
      File.mkdir_p!(Path.join(root, "cache"))
      prev = System.get_env("LCARS_STORE_ROOT")
      System.put_env("LCARS_STORE_ROOT", root)

      on_exit(fn ->
        if prev,
          do: System.put_env("LCARS_STORE_ROOT", prev),
          else: System.delete_env("LCARS_STORE_ROOT")

        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    defp envd(root, name, body), do: File.write!(Path.join([root, "state/env.d", name]), body)

    defp cap,
      do: %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{"name" => "t"}, spec: %{}}

    test "DEUX montages, et le `rw` du cache vient APRES le `ro` de l'arbre", %{root: root} do
      env = LaunchSpec.pod_mounts_env(cap(), [], "/opt/claude_launch.sh")
      ro = :binary.match(env, "ro:#{root}\n") |> elem(0)
      rw = :binary.match(env, "rw:#{Path.join(root, "cache")}") |> elem(0)

      # The writable cache must overlay the read-only store, in bwrap mount order.
      assert ro < rw
    end

    test "pas de cache sur le disque : le `ro` seul, jamais un `rw` invente", %{root: root} do
      File.rm_rf!(Path.join(root, "cache"))
      env = LaunchSpec.pod_mounts_env(cap(), [], "/opt/claude_launch.sh")
      assert env =~ "ro:#{root}"
      refute env =~ "rw:#{Path.join(root, "cache")}"
    end

    test "aucun magasin : la ligne est celle d'aujourd'hui, octet pour octet (DR-023)" do
      System.delete_env("LCARS_STORE_ROOT")
      assert LaunchSpec.toolchain_env() == ""
      refute LaunchSpec.pod_mounts_env(cap(), [], "/opt/claude_launch.sh") =~ "lcars-store-test"
    end

    test "env.d vide : le montage, et AUCUN --setenv de plus" do
      assert LaunchSpec.toolchain_env() == ""
    end

    test "deux fichiers : union, ordre stable, commentaires et blancs ignores", %{root: root} do
      envd(root, "10-rust.env", "# la toolchain rust\nCARGO_HOME=/store/toolchains/rust\n\n")
      envd(root, "20-esp.env", "IDF_PATH=/store/toolchains/esp-idf\n")

      assert LaunchSpec.toolchain_env() ==
               "CARGO_HOME=/store/toolchains/rust\nIDF_PATH=/store/toolchains/esp-idf"
    end

    test "une valeur peut contenir `=` — on coupe au PREMIER", %{root: root} do
      envd(root, "a.env", "OPTS=--flag=value\n")
      assert LaunchSpec.toolchain_env() == "OPTS=--flag=value"
    end

    test "newline dans une valeur => REFUS du spawn, pas un env tronque", %{root: root} do
      envd(root, "a.env", "A=x\nB=y\n")
      # Two valid physical lines are accepted. The following case rejects an embedded CR.
      assert LaunchSpec.toolchain_env() == "A=x\nB=y"

      envd(root, "b.env", "C=avec\rretour\n")

      assert_raise ArgumentError, ~r/SECURITY REFUSAL/, fn -> LaunchSpec.toolchain_env() end
    end

    test "clef hors motif => REFUS", %{root: root} do
      envd(root, "a.env", "bad-key=1\n")

      assert_raise ArgumentError, ~r/not a shell environment name/, fn ->
        LaunchSpec.toolchain_env()
      end
    end

    test "ligne sans `=` => REFUS (ce fichier n'est pas du shell)", %{root: root} do
      envd(root, "a.env", "export FOO\n")
      assert_raise ArgumentError, ~r/no `=`/, fn -> LaunchSpec.toolchain_env() end
    end

    test "une variable de build UNIVERSELLE est LARGUEE, pas refusee", %{root: root} do
      # Dropping global build vars protects unrelated pods without blocking every spawn.
      envd(root, "a.env", "CC=aarch64-linux-gnu-gcc\nCARGO_HOME=/store/rust\n")
      assert LaunchSpec.toolchain_env() == "CARGO_HOME=/store/rust"
    end
  end
end
