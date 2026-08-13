defmodule Fleet.Spawner.SeedStoreTest do
  @moduledoc "Seed-store checkpoint (pod-seed v2)."
  # async:false — `seed_store_root` is global config (Application env).
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Spawner.SeedStore

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "seedroot")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_seed_store_root, root)

    %{tmp: tmp, root: root}
  end

  defp make_jsonl(pod_dir, slug, uuid, content) do
    dir = Path.join([pod_dir, ".claude", "projects", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{uuid}.jsonl")
    File.write!(path, content)
    path
  end

  test "checkpoint: keeps the FIRST ROUND only (up to the 1st assistant) + workflow_map", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")

    content =
      ~s({"type":"user","message":"r1"}\n{"type":"assistant","message":"ok"}\n{"type":"user","message":"r2"}\n)

    # The live jsonl's uuid ("uuid-abc") is NOT the stored identity; the passed builder is.
    make_jsonl(pod_dir, "-home-x-poc8-engineer", "uuid-abc", content)

    assert :ok = SeedStore.checkpoint(pod_dir, "poc-8", "engineer", "builder-det", nil)

    seed = File.read!(Path.join([root, "poc-8", "pods", "engineer.jsonl"]))
    # round 1 (user + assistant) kept; round 2 discarded.
    assert seed =~ "r1"
    assert seed =~ "assistant"
    refute seed =~ "r2"

    map = Path.join([root, "poc-8", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()

    # uuid = the passed builder (single source). slug = cwd-slug of the live jsonl (content).
    assert %{
             "uuid" => "builder-det",
             "slug" => "-home-x-poc8-engineer",
             "role" => "engineer",
             "project" => "poc-8"
           } = map
  end

  test "checkpoint: workflow_map = passed builder, NOT the live jsonl's uuid (/clear rotation)",
       %{
         tmp: tmp,
         root: root
       } do
    pod_dir = Path.join(tmp, "pod")
    old = make_jsonl(pod_dir, "slug", "old-uuid", "old\n")
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    make_jsonl(pod_dir, "slug", "new-uuid", "new\n")

    # Two live jsonl files (a `/clear` rotated the uuid). Contract: the workflow_map carries the
    # PASSED builder (single source), INDEPENDENTLY of the live jsonl's uuid — neither the old nor
    # the recent one.
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det", nil)

    map = Path.join([root, "p", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()
    assert map["uuid"] == "builder-det"
    refute map["uuid"] == "new-uuid"

    # The CONTENT always comes from the ACTIVE jsonl = the most recent (the live session, post-/clear).
    assert File.read!(Path.join([root, "p", "pods", "engineer.jsonl"])) == "new\n"
  end

  test "checkpoint: no JSONL → :none, nothing written", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "empty-pod")
    File.mkdir_p!(pod_dir)

    assert :none = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det", nil)
    refute File.exists?(Path.join(root, "p"))
  end

  test "slugify: reproduces the real claude slug (proven 2.1.183)" do
    assert SeedStore.slugify("/home/starfleet/pods/pod_fleet-poc-8-issue-6-consultant/workspace") ==
             "-home-starfleet-pods-pod-fleet-poc-8-issue-6-consultant-workspace"

    assert SeedStore.slugify("/home/x/resume-test__9c62d00f") == "-home-x-resume-test--9c62d00f"
  end

  test "slugify: RE-CONFRONTE au binaire vendor 2.1.220 (temoins mesures, pas rejoues)" do
    # Le contrat etait gele contre la v2.1.183 et jamais re-confronte depuis. Le binaire d'une
    # boite est en 2.1.220 — trois versions plus loin — et une derive ici ne casse RIEN
    # visiblement : le resume pointe vers un repertoire vide, donc un pod repart sans sa memoire
    # au lieu d'echouer. C'est la moitie muette du contrat vendor (BL-6-44).
    #
    # Ces deux attentes ne sont pas deduites de notre code : elles sont les noms de repertoire que
    # le binaire vendor a REELLEMENT ecrits sous `~/.claude/projects/` le 2026-08-03, depuis les
    # deux `cwd` ci-dessous, sur un binaire 2.1.220. Un test qui rejouerait notre propre fonction
    # re-affirmerait notre lecture de l'algo ; ceux-la confrontent.
    #
    # 🛑 CES TEMOINS NE SE RE-PRODUISENT PAS AVEC `--print`. Ce mode est INTERDIT ici : hors
    # abonnement il n'est pas cher, il est BLOQUE — la facturation a l'unite est mesuree a 90 $ en
    # 2 h contre 90 $/mois d'abonnement, donc le jour ou le vendor l'en sort, c'est un mur, pas une
    # ligne de budget. `claude_launch.sh` le dit au site de lancement (ADR-G : « NO -p, NO
    # stream-json »). Pour rafraichir ces temoins : `mix lcars.slug_witness --root <arbre de pods>`,
    # qui lit ce que des pods NORMAUX ont ecrit au lieu d'en fabriquer.
    #
    # Le second cas est le DISCRIMINANT : `__` et deux espaces donnent `----` — l'absence de
    # collapsing est exactement ce qui distingue l'algo gele d'une slugification naive, et c'est
    # le seul endroit ou une divergence se verrait.
    assert SeedStore.slugify("/tmp/witness/pod_a.b-c") == "-tmp-witness-pod-a-b-c"
    assert SeedStore.slugify("/tmp/w2/pod__x  y") == "-tmp-w2-pod--x--y"
  end

  test "read_map: workflow_map + jsonl present → {:ok, uuid}, otherwise :none", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det", nil)

    # read_map re-reads the workflow_map's uuid = the stored builder, NOT the live jsonl's uuid ("u1").
    assert {:ok, %{uuid: "builder-det"}} = SeedStore.read_map("p", "engineer", nil)
    assert :none = SeedStore.read_map("p", "inexistant", nil)
  end

  test "restore: cp the seed at the recall cwd's slug, findable by --resume", %{tmp: tmp} do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "u9")

    assert dest == Path.join([pod_dir, ".claude", "projects", "-home-r-recallpod", "u9.jsonl"])
    assert File.read!(dest) == "mem\n"
  end

  test "Spawner.recall: no seed for (project, role, ticket) → {:error, :no_seed}" do
    assert {:error, :no_seed} = Fleet.Spawner.recall("nonexistent-project", "engineer", 42)
  end

  describe "recall keying — the seed of a ticket-scoped role is per TICKET" do
    test "recalling a ticket-keyed role WITHOUT a ticket is refused by name" do
      # `engineer` declares `slot_scope: instance`, so "the engineer of project P" no longer names
      # one session: each of its tickets checkpointed its own. Serving whichever died last is
      # exactly the defect the per-ticket key removes — so the ambiguity is refused, not resolved.
      assert {:error, {:ticket_required, "engineer"}} =
               Fleet.Spawner.recall("nonexistent-project", "engineer")
    end

    test "naming a ticket for a project-keyed role is refused too" do
      # The symmetric mismatch: an architect has ONE seed per project and no ticket to name.
      # Accepting the argument and ignoring it would let a caller believe it selected something.
      assert {:error, {:ticket_not_applicable, "architect"}} =
               Fleet.Spawner.recall("nonexistent-project", "architect", 42)
    end

    test "two tickets of the same role checkpoint to DISTINCT seeds", %{tmp: tmp} do
      # The measured defect: keyed on (project, role), the engineers of tickets 41 and 42 wrote the
      # same file and the last to die won — a recall then resumed another ticket's conversation.
      round = ~s({"type":"user","message":"r1"}\n{"type":"assistant","message":"ok"}\n)

      pod_41 = Path.join(tmp, "pod41")
      make_jsonl(pod_41, "-home-x-p-engineer", "live-41", round)
      assert :ok = SeedStore.checkpoint(pod_41, "p", "engineer", "det-41", 41)

      pod_42 = Path.join(tmp, "pod42")
      make_jsonl(pod_42, "-home-x-p-engineer", "live-42", round)
      assert :ok = SeedStore.checkpoint(pod_42, "p", "engineer", "det-42", 42)

      assert {:ok, %{uuid: "det-41"}} = SeedStore.read_map("p", "engineer", 41)
      assert {:ok, %{uuid: "det-42"}} = SeedStore.read_map("p", "engineer", 42)

      # And the per-role name is NOT collaterally written: a project-keyed seed for the same role
      # would be a different object, and this must not squat it.
      assert :none = SeedStore.read_map("p", "engineer", nil)
    end
  end

  # ============================================================
  # Confinement E (WI-E1) — a non-slug project/role name NEVER traverses the seed-store.
  # ============================================================

  test "checkpoint: traversing project (../evil) → REFUSED, nothing written outside the store", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")

    # Escape target: `<root>/../evil/pods/...` = a SIBLING directory of the seed-store root.
    evil_dir = Path.expand(Path.join(root, "../evil"))

    assert {:error, _} = SeedStore.checkpoint(pod_dir, "../evil", "engineer", "builder-det", nil)

    # Proven regression: without the slug+confinement guard, `Path.join([root, "../evil", "pods"])`
    # would write `engineer.jsonl` HERE, outside the root. The guard makes it unrepresentable.
    refute File.exists?(evil_dir)
    refute File.exists?(Path.join([root, "..", "evil"]))
  end

  test "checkpoint: traversing role (a/b) → REFUSED", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "p", "a/b", "builder-det", nil)
  end

  test "checkpoint: empty / NUL / control names → REFUSED", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "", "engineer", "builder-det", nil)

    assert {:error, _} =
             SeedStore.checkpoint(pod_dir, "ok\x00evil", "engineer", "builder-det", nil)

    assert {:error, _} = SeedStore.checkpoint(pod_dir, "ok\nevil", "engineer", "builder-det", nil)
  end

  test "checkpoint: valid name (my_checkpoint-1) → accepted", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "my_checkpoint-1", "engineer", "builder-det", nil)
    assert File.exists?(Path.join([root, "my_checkpoint-1", "pods", "engineer.jsonl"]))
  end

  test "read_map: traversing project → :none (does not read outside the store)", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det", nil)
    assert :none = SeedStore.read_map("../p", "engineer", nil)
    assert :none = SeedStore.read_map("p", "../engineer", nil)
  end

  test "restore: uuid escaping the pod_dir → REFUSED (fail-loud raise), no write outside the pod",
       %{
         tmp: tmp
       } do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    # hostile uuid (read from a corrupted seed-map): the write leaf is `pod_dir/.claude/projects/
    # <slug>/` (3 levels under the pod) → 4 `../` are needed to cross the pod_dir and target a host
    # file (`tmp/escaped.jsonl`). `restore` confines `dest` under `pod_dir` via `under_root?` BEFORE
    # the `cp!`: an escape MUST raise (the caller folds the raise onto transition_failed, the pod
    # does not launch). A uuid staying under the pod (e.g. `../../x` → `.claude/x.jsonl`) is
    # legitimate — the pod is ephemeral and owned; the only real vector closed here is writing
    # OUTSIDE the pod.
    escape_target = Path.expand(Path.join(tmp, "escaped.jsonl"))
    File.rm(escape_target)

    assert_raise ArgumentError, fn ->
      SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "../../../../escaped")
    end

    refute File.exists?(escape_target)
  end

  describe "Desktop-slot bridge_status sidecar (2026-07-19)" do
    @uuid "1badcafe-feed-4dad-babe-9999dec0de04"
    @bridge ~s({"type":"system","subtype":"bridge_status","url":"https://claude.ai/code/session_01ABC","sessionId":"1badcafe-feed-4dad-babe-9999dec0de04"})

    test "capture: writes the most recent bridge_status to <root>/_slots/<uuid>.jsonl", %{
      tmp: tmp,
      root: root
    } do
      pod_dir = Path.join(tmp, "pod")

      content =
        ~s({"type":"system","subtype":"mode"}\n) <>
          @bridge <> "\n" <> ~s({"type":"user","message":"hi"}\n)

      make_jsonl(pod_dir, "-home-x-arch", @uuid, content)

      assert :ok = SeedStore.capture_slot_bridge(pod_dir, @uuid)

      sidecar = Path.join([root, "_slots", "#{@uuid}.jsonl"])
      assert File.exists?(sidecar)
      line = sidecar |> File.read!() |> String.trim()
      assert line =~ "bridge_status"
      assert line =~ "session_01ABC"
    end

    test "capture: :none when the live jsonl has NO bridge_status (not registered yet)", %{
      tmp: tmp
    } do
      pod_dir = Path.join(tmp, "pod")
      make_jsonl(pod_dir, "-home-x-arch", @uuid, ~s({"type":"system","subtype":"mode"}\n))
      assert :none = SeedStore.capture_slot_bridge(pod_dir, @uuid)
    end

    test "capture: :none when there is no live jsonl at all", %{tmp: tmp} do
      pod_dir = Path.join(tmp, "emptypod")
      File.mkdir_p!(pod_dir)
      assert :none = SeedStore.capture_slot_bridge(pod_dir, @uuid)
    end

    test "restore: injects the captured bridge_status onto the restored seed (F5 reattach)", %{
      tmp: tmp,
      root: root
    } do
      File.mkdir_p!(Path.join(root, "_slots"))
      File.write!(Path.join([root, "_slots", "#{@uuid}.jsonl"]), @bridge <> "\n")

      seed = Path.join(tmp, "base.jsonl")

      File.write!(
        seed,
        ~s({"type":"system","subtype":"mode"}\n{"type":"user","message":"setup"}\n)
      )

      pod_dir = Path.join(tmp, "recallpod")

      {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallpod", @uuid)
      restored = File.read!(dest)
      assert restored =~ "setup", "seed body must be kept"
      assert restored =~ "bridge_status", "slot line must be grafted"
      assert restored =~ "session_01ABC"
    end

    test "restore: idempotent — no double-inject if the seed already carries a bridge_status", %{
      tmp: tmp,
      root: root
    } do
      File.mkdir_p!(Path.join(root, "_slots"))
      File.write!(Path.join([root, "_slots", "#{@uuid}.jsonl"]), @bridge <> "\n")

      seed = Path.join(tmp, "base.jsonl")
      File.write!(seed, @bridge <> "\n")
      pod_dir = Path.join(tmp, "recallpod2")

      {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallpod2", @uuid)
      occurrences = dest |> File.read!() |> String.split("bridge_status") |> length()
      assert occurrences == 2, "expected exactly 1 bridge_status, got #{occurrences - 1}"
    end

    test "capture then restore: round-trip re-attaches the same slot line", %{tmp: tmp} do
      # boot 1: a live jsonl registered a slot → capture
      pod1 = Path.join(tmp, "pod1")
      make_jsonl(pod1, "-home-x-arch", @uuid, @bridge <> "\n")
      assert :ok = SeedStore.capture_slot_bridge(pod1, @uuid)

      # boot 2: restore a fresh base seed (no slot) → the captured slot is grafted back
      seed = Path.join(tmp, "base.jsonl")
      File.write!(seed, ~s({"type":"system","subtype":"mode"}\n))
      pod2 = Path.join(tmp, "pod2")
      {:ok, dest} = SeedStore.restore(seed, pod2, "/home/r/pod2", @uuid)
      assert File.read!(dest) =~ "session_01ABC"
    end

    # The RESUMED-session format (the arch, manual-mode): the RC identity is a `bridge-session`
    # record (bridgeSessionId = the slot), NOT `system/bridge_status`. Proven live 2026-07-19 that
    # injecting it re-attaches the arch's `cse_…` slot. Capture must grab this format too.
    @bridge_session ~s({"type":"bridge-session","sessionId":"1badcafe-feed-4dad-babe-9999dec0de04","bridgeSessionId":"cse_01ABC","lastSequenceNum":0})

    test "capture: grabs the bridge-session record (resumed-session format, e.g. the arch)", %{
      tmp: tmp,
      root: root
    } do
      pod_dir = Path.join(tmp, "pod")

      make_jsonl(
        pod_dir,
        "-home-x-arch",
        @uuid,
        ~s({"type":"system","subtype":"mode"}\n) <> @bridge_session <> "\n"
      )

      assert :ok = SeedStore.capture_slot_bridge(pod_dir, @uuid)
      captured = Path.join([root, "_slots", "#{@uuid}.jsonl"]) |> File.read!()
      assert captured =~ "bridge-session"
      assert captured =~ "cse_01ABC"
    end

    test "restore: injects a captured bridge-session (arch reattach)", %{tmp: tmp, root: root} do
      File.mkdir_p!(Path.join(root, "_slots"))
      File.write!(Path.join([root, "_slots", "#{@uuid}.jsonl"]), @bridge_session <> "\n")

      seed = Path.join(tmp, "base.jsonl")
      File.write!(seed, ~s({"type":"user","message":"setup"}\n))
      pod_dir = Path.join(tmp, "recallarch")

      {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallarch", @uuid)
      restored = File.read!(dest)
      assert restored =~ "setup", "seed body kept"
      assert restored =~ "cse_01ABC", "arch slot line grafted"
    end

    test "restore: idempotent on an already-present bridge-session", %{tmp: tmp, root: root} do
      File.mkdir_p!(Path.join(root, "_slots"))
      File.write!(Path.join([root, "_slots", "#{@uuid}.jsonl"]), @bridge_session <> "\n")

      seed = Path.join(tmp, "base.jsonl")
      File.write!(seed, @bridge_session <> "\n")
      pod_dir = Path.join(tmp, "recallarch2")

      {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallarch2", @uuid)
      occurrences = dest |> File.read!() |> String.split("bridge-session") |> length()
      assert occurrences == 2, "expected exactly 1 bridge-session, got #{occurrences - 1}"
    end
  end

  describe "sidecar-as-SEED (unified seed, reorg 2026-07-19)" do
    @uuid "1badcafe-feed-4dad-babe-9999dec0de04"
    @bridge ~s({"type":"system","subtype":"bridge_status","url":"https://claude.ai/code/session_01ABC","sessionId":"1badcafe-feed-4dad-babe-9999dec0de04"})
    @mode ~s({"type":"mode","mode":"default"})
    @perm ~s({"type":"permission-mode","mode":"default"})

    test "capture stores the FULL F5 seed set (mode + permission-mode + identity)", %{
      tmp: tmp,
      root: root
    } do
      pod_dir = Path.join(tmp, "pod-seed")
      make_jsonl(pod_dir, "-home-x", @uuid, Enum.join([@mode, @perm, @bridge], "\n") <> "\n")

      assert :ok = SeedStore.capture_slot_bridge(pod_dir, @uuid)

      sidecar = File.read!(Path.join([root, "_slots", "#{@uuid}.jsonl"]))
      assert sidecar =~ ~s("type":"mode")
      assert sidecar =~ ~s("type":"permission-mode")
      assert sidecar =~ "bridge_status"
    end

    test "capture MERGES by type — a resumed session that re-emits only the identity keeps the seed full",
         %{tmp: tmp, root: root} do
      # Boot A captured the full set; boot B's live jsonl carries ONLY a (newer) identity line.
      File.mkdir_p!(Path.join(root, "_slots"))

      File.write!(
        Path.join([root, "_slots", "#{@uuid}.jsonl"]),
        Enum.join([@mode, @perm, @bridge], "\n") <> "\n"
      )

      newer = ~s({"type":"bridge-session","bridgeSessionId":"cse_01NEW"})
      pod_dir = Path.join(tmp, "pod-seed-b")
      make_jsonl(pod_dir, "-home-x", @uuid, newer <> "\n")

      assert :ok = SeedStore.capture_slot_bridge(pod_dir, @uuid)

      sidecar = File.read!(Path.join([root, "_slots", "#{@uuid}.jsonl"]))
      # The newer identity landed AND the mode/permission records survived (never thins).
      assert sidecar =~ "cse_01NEW"
      assert sidecar =~ ~s("type":"mode")
      assert sidecar =~ ~s("type":"permission-mode")
    end

    test "capture stays :none pre-registration EVEN IF mode/permission are present", %{tmp: tmp} do
      # A seed without an identity line would resume but re-attach NO slot — refused.
      pod_dir = Path.join(tmp, "pod-prereg")
      make_jsonl(pod_dir, "-home-x", @uuid, Enum.join([@mode, @perm], "\n") <> "\n")
      assert :none = SeedStore.capture_slot_bridge(pod_dir, @uuid)
    end

    test "slot_seed/1: {:ok, path} for a captured identity, :none otherwise", %{root: root} do
      assert :none = SeedStore.slot_seed(@uuid)
      assert :none = SeedStore.slot_seed("not-a-uuid")

      File.mkdir_p!(Path.join(root, "_slots"))
      path = Path.join([root, "_slots", "#{@uuid}.jsonl"])
      File.write!(path, @bridge <> "\n")

      assert {:ok, ^path} = SeedStore.slot_seed(@uuid)
    end
  end

  describe "JSONL scan budget (the capture/teardown callback must never scan unbounded)" do
    test "a MARKER-LESS enormous transcript is scanned only up to the budget, not to EOF", %{
      tmp: tmp,
      root: root
    } do
      pod_dir = Path.join(tmp, "pod")

      # No `assistant` line anywhere → first_round's content-halt never fires; only the byte/
      # line budget stops the walk. Well over the 8 MB / 50k-line caps.
      line = ~s({"type":"user","message":"#{String.duplicate("x", 400)}"}\n)
      huge = String.duplicate(line, 60_000)
      make_jsonl(pod_dir, "-home-x-poc9-engineer", "uuid-huge", huge)

      # The checkpoint completes (never hangs) and writes a bounded seed — well under the
      # full input, capped at the budget.
      assert :ok = SeedStore.checkpoint(pod_dir, "poc-9", "engineer", "builder-det", nil)

      seed = File.read!(Path.join([root, "poc-9", "pods", "engineer.jsonl"]))
      assert byte_size(seed) <= 8_000_000
      assert byte_size(seed) < byte_size(huge)
    end
  end

  # JG-086 (`S1`) — LE POD POSSEDE LES INODES DE SON ARBRE, ET LE DAEMON LES SUIVAIT.
  # `<pod_dir>` est bind-monte READ-WRITE dans le sandbox (`bwrap_launch.sh`). Un lien pose par
  # l'agent — sur la feuille `.jsonl` ou sur n'importe quel repertoire au-dessus — faisait lire au
  # daemon, qui tourne SOUS L'HUMAIN et HORS du sandbox, un fichier de son choix ; le contenu
  # partait dans la graine et revenait dans le pod suivant. La LECTURE est l'exfiltration.
  #
  # `Fleet.Slug.under_root?/2` ne voit rien de tout cela : il compare des chaines. C'est le bon
  # controle contre un `..` dans un nom et aucun controle contre un lien — d'ou son jumeau
  # non-lexical `link_free_under?/2`, pose a cote de lui pour que la difference se voie.
  describe "JG-086 — un lien dans le pod_dir ne fait plus lire ni ecrire le daemon ailleurs" do
    test "LECTURE : un .jsonl symlinke vers un fichier de l'hote est IGNORE", %{
      tmp: tmp,
      root: root
    } do
      pod_dir = Path.join(tmp, "pod")
      secret = Path.join(tmp, "host-secret.env")
      File.write!(secret, ~s({"type":"user","message":{"content":"TOKEN=deadbeef"}}\n))

      dir = Path.join([pod_dir, ".claude", "projects", "slug"])
      File.mkdir_p!(dir)
      File.ln_s!(secret, Path.join(dir, "aaaa-bbbb.jsonl"))

      assert :none = SeedStore.checkpoint(pod_dir, "proj", "engineer", "aaaa-bbbb", nil)
      refute File.exists?(Path.join([root, "proj", "pods"]))
    end

    test "LECTURE : un REPERTOIRE intermediaire symlinke est ignore aussi (le lien n'est pas que sur la feuille)",
         %{tmp: tmp, root: root} do
      pod_dir = Path.join(tmp, "pod")
      elsewhere = Path.join(tmp, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "slug"))
      File.write!(Path.join([elsewhere, "slug", "cccc-dddd.jsonl"]), ~s({"type":"user"}\n))

      File.mkdir_p!(Path.join(pod_dir, ".claude"))
      File.ln_s!(elsewhere, Path.join([pod_dir, ".claude", "projects"]))

      assert :none = SeedStore.checkpoint(pod_dir, "proj", "engineer", "cccc-dddd", nil)
      refute File.exists?(Path.join([root, "proj", "pods"]))
    end

    test "TEMOIN : un fichier REGULIER au meme endroit est bien capture", %{tmp: tmp, root: root} do
      pod_dir = Path.join(tmp, "pod")
      make_jsonl(pod_dir, "slug", "eeee-ffff", ~s({"type":"user","message":{"content":"hi"}}\n))

      assert :ok = SeedStore.checkpoint(pod_dir, "proj", "engineer", "eeee-ffff", nil)
      assert File.exists?(Path.join([root, "proj", "pods", "engineer.jsonl"]))
    end

    test "ECRITURE : un slug destination symlinke fait REFUSER le restore, rien n'est ecrit dehors",
         %{tmp: tmp} do
      pod_dir = Path.join(tmp, "pod")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)

      seed = Path.join(tmp, "seed.jsonl")
      File.write!(seed, ~s({"type":"user","sessionId":"old"}\n))

      cwd = "/home/projects/demo"
      dir = Path.join([pod_dir, ".claude", "projects"])
      File.mkdir_p!(dir)
      File.ln_s!(outside, Path.join(dir, SeedStore.slugify(cwd)))

      assert_raise ArgumentError, ~r/symlink stands between/, fn ->
        SeedStore.restore(seed, pod_dir, cwd, "1111-2222")
      end

      assert File.ls!(outside) == [], "le daemon a ecrit hors du monde projete"
    end

    test "TEMOIN ECRITURE : sans lien, le restore ecrit bien au bon endroit", %{tmp: tmp} do
      pod_dir = Path.join(tmp, "pod")
      seed = Path.join(tmp, "seed.jsonl")
      File.write!(seed, ~s({"type":"user","sessionId":"old"}\n))

      assert {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/projects/demo", "3333-4444")
      assert File.exists?(dest)
      assert Fleet.Slug.link_free_under?(dest, pod_dir)
    end
  end
end
