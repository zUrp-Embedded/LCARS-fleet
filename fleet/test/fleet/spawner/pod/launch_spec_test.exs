defmodule Fleet.Spawner.Pod.LaunchSpecTest do
  # `async: false` : ce fichier ECRIT `LCARS_STORE_ROOT`, globale au NOEUD (bloc « magasin
  # d'outillage » plus bas, ou le raisonnement complet est ecrit). Un second module l'ecrit aussi ;
  # en parallele, leurs restaurations se marchent dessus.
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
      # This is the whole point. `project_delete` nukes the faces without consulting running pods;
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

  # ⚠ CE COMMENTAIRE DISAIT « `async: false` sur ce bloc », ET CE MECANISME N'EXISTE PAS. Le mode
  # `async` d'ExUnit se declare une fois par MODULE, dans `use ExUnit.Case` — il n'y a pas d'`async`
  # par `describe`. La protection annoncee ici n'a donc jamais existe : ce bloc ecrivait
  # `LCARS_STORE_ROOT`, variable d'environnement GLOBALE AU NOEUD, pendant que le module entier
  # tournait en parallele des autres.
  #
  # MESURE DU 2026-08-20, dans un `mix gate` complet : « clef hors motif => REFUS » n'a rien leve.
  # `Fleet.Pilot.IncidentRegistryTest` — `async: true` lui aussi — ecrit et RESTAURE la meme variable
  # dans son `with_store/2` ; sa restauration, tombee au milieu d'un test d'ici, a fait lire une
  # racine qui n'etait pas la sienne, ou le fichier `bad-key=1` n'existe pas. Le test attendait un
  # refus et a vu une lecture propre. Il passait seul et echouait en suite complete, donc la seule
  # facon de le voir etait de le faire tomber.
  #
  # Le fichier est desormais `async: false` (en tete), des DEUX cotes. La regle que `Fleet.TestEnv`
  # enonce pour l'env d'APPLICATION vaut mot pour mot pour l'env OS : un fichier qui l'ecrit est
  # `async: false`, et aucun commentaire ne remplace le mot-clef.
  describe "le magasin d'outillage — monte, et l'environnement qui le rend utilisable" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "lcars-store-test-#{System.unique_integer([:positive])}")

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

      # L'ORDRE EST LE SENS : bwrap applique dans l'ordre, donc le rw doit recouvrir le ro. Les
      # inverser rend le cache lisible et non ecrivable — `EROFS` au premier `pip install`, avec
      # l'air d'etre configure.
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
      # Deux lignes valides : ce cas passe. L'injection se fait par un ECHAPPEMENT dans la valeur,
      # que le format ne permet pas — la garde est verifiee sur la clef ci-dessous et sur `\r` ici.
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
      # L'asymetrie est deliberee : un fichier malforme est un bug du producteur et arrete la ligne ;
      # une variable universelle est une violation de politique dont le rayon d'action est LES AUTRES
      # pods. Refuser le spawn laisserait un seul mauvais env.d tuer tous les pods de la boite.
      envd(root, "a.env", "CC=aarch64-linux-gnu-gcc\nCARGO_HOME=/store/rust\n")
      assert LaunchSpec.toolchain_env() == "CARGO_HOME=/store/rust"
    end
  end
end
