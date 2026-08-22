defmodule Fleet.Pilot.BriefBuilderTest do
  @moduledoc """
  F-C083 — LOCK on the DELIVERABLE-JUDGE criterion. The criterion (issue body) is read from the forge
  by `build_judge_brief`. A forge READ-ERROR on this criterion must NEVER produce a "criterion-less"
  judge (the judge gets the diff but NO criterion → risk of blind approval = false GREEN).

  `read-error ≠ absence`: the deliverable-judge path of `build_brief` returns `{:ok, brief, kind}` when the
  criterion is readable (present OR genuinely absent = rare real state) and
  `{:error, {:criterion_unavailable, reason}}` ONLY on a read failure → the dispatch defers (skip,
  retry), it does not spawn a blind judge.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.BriefBuilder

  # Minimal forge seam: `get_predecessor_result` (the DELIVERABLE) + `issue_get` (the CRITERION),
  # driven by `forge_opts` (`:_pred`, `:_issue`) → a single stub serves the ok/error cases.
  defmodule StubForge do
    def get_predecessor_result(_repo, _n, opts),
      do: Keyword.get(opts, :_pred, {:ok, %{"livrable" => "diff stub"}})

    def get_issue(_repo, _n, opts),
      do: Keyword.get(opts, :_issue, {:ok, %{"body" => "CRITÈRE-XYZ"}})
  end

  # Deliverable-JUDGE profile (modeled on the dispatch StubLoader: reviewer/qualifier, brief_kind:
  # judge, slot_scope instance). step_spec `%{}` + judge_target absent → build_judge_brief (judges
  # the deliverable/PR).
  defp judge_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "reviewer"},
      spec: %{"brief_kind" => "judge"}
    }
  end

  # These tests assert the brief TEXT and kind; the 4th element (the mandate mount) is asserted by
  # its own test ("build_brief SURFACES the mandate mount", below) and consumed end-to-end by
  # step_dispatcher_test's "PR judge with a Criteria: pointer → spawn_opts[:mandate]". Strip it here
  # so these assertions stay on the 3-tuple they care about.
  defp build(forge_opts, opts \\ []) do
    case BriefBuilder.build_brief(
           judge_profile(),
           "reviewer",
           StubForge,
           "acme/widget",
           42,
           %{},
           forge_opts,
           {"pipe", "review"},
           %{},
           opts
         ) do
      {:ok, brief, kind, _mount} -> {:ok, brief, kind}
      other -> other
    end
  end

  # Same call, but keeps the 4th element: the mount source is where the "which doc" invariant lives
  # now that the order text cites no ref (transport_brief_v2).
  defp build4(forge_opts, opts) do
    BriefBuilder.build_brief(
      judge_profile(),
      "reviewer",
      StubForge,
      "acme/widget",
      42,
      %{},
      forge_opts,
      {"pipe", "review"},
      %{},
      opts
    )
  end

  describe "build_brief — the CI fact rides into the judge brief (porte CI)" do
    test "a measured green CI is HANDED to the judge, with the boundary of what it means" do
      assert {:ok, brief, "judge"} =
               build([], ci_fact: %{state: :success, sha: "cafebabe1234567890"})

      # The sha the GATE measured — not one the builder re-read (a second read = a second truth).
      assert brief =~ "cafebabe"
      # And the line that keeps a green CI from being read as a green review.
      assert brief =~ "PROUVE"
    end

    test "no CI fact (card on `ci: ignore`) → NOTHING is said, rather than 'CI: unknown'" do
      assert {:ok, brief, "judge"} = build([])
      refute brief =~ "CI VERTE"
    end

    test "a non-success fact never reaches the judge — the gate does not summon on those" do
      assert {:ok, brief, "judge"} = build([], ci_fact: %{state: :failure, sha: "deadbeef00"})
      refute brief =~ "deadbeef"
    end

    test "6-140 : le brief NOMME ce qui a tourne, et ne dit plus qu'une preuve a ete executee" do
      # La phrase disait « le rail machine a EXECUTE la preuve ». Le rail livre avec le template
      # execute deux `echo` — donc sur tout projet fraichement onboarde, le juge recevait « une
      # preuve a ete executee » alors qu'aucune ne l'avait ete.
      assert {:ok, brief, "judge"} =
               build([],
                 ci_fact: %{
                   state: :success,
                   sha: "cafebabe1234567890",
                   contexts: ["CI / no-harness-yet (pull_request)"]
                 }
               )

      refute brief =~ "EXECUTE la preuve"
      assert brief =~ "CI / no-harness-yet (pull_request)"
      # Et l'absence de harnais devient une constatation attendue, pas un fait invisible.
      assert brief =~ "EST une constatation"
    end

    test "6-140 : des contextes illisibles se DISENT, ils ne se fabriquent pas" do
      # Un seam qui n'expose pas la lecture des contextes degrade honnetement : le brief dit ce
      # qu'il sait. Ecrire la phrase « ce qui a tourne » sur une liste vide laisserait croire a une
      # verification qui n'a pas eu lieu.
      assert {:ok, brief, "judge"} =
               build([], ci_fact: %{state: :success, sha: "cafebabe1234567890", contexts: []})

      assert brief =~ "n'ont pas pu etre lus"
      refute brief =~ "Ce qui a tourne, exactement"
    end
  end

  describe "build_brief — deliverable-judge, criterion read (F-C083)" do
    test "get_issue OK → {:ok, brief, \"judge\"} that CARRIES the criterion (defused by GateBrief)" do
      assert {:ok, brief, "judge"} = build(_issue: {:ok, %{"body" => "CRITÈRE-XYZ"}})
      assert is_binary(brief)

      # The criterion is rendered DEFUSED ("Original request (CONTEXT — DO NOT execute)" section) → present.
      assert brief =~ "CRITÈRE-XYZ"
    end

    test "get_issue READ-ERROR → {:error, {:criterion_unavailable, reason}} (NEVER a criterion-less judge)" do
      # Core of the finding: a transient read-error must NOT conflate into `request: nil`. A judge that
      # gets the diff but no criterion may approve blindly (false GREEN). TYPED fail-closed → defers.
      assert {:error, {:criterion_unavailable, :boom}} = build(_issue: {:error, :boom})
    end

    test "genuinely absent issue body (get_issue OK, body nil) → {:ok, brief, kind}: absence ≠ read-error" do
      # Load-bearing distinction: `{:ok, issue}` without body = REAL state (rare) → we PROCEED (the
      # judge has the diff via `outputs`, GateBrief renders an empty criterion). Only the read-error
      # defers: no over-fixing.
      assert {:ok, _brief, "judge"} = build(_issue: {:ok, %{"number" => 42}})
    end

    @tag :tmp_dir
    test "the judge's criterion is the CRITERIA doc, not the brief, when both are pointed",
         %{tmp_dir: tmp} do
      # The bench bug, closed: a single brief used to serve both consumers, so the judge got the
      # producer's procedural order. Here the ticket points at BOTH a brief and a criteria; the
      # judge must resolve the CRITERIA (gate-briefs/), never the brief (briefs/).
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "briefs"))
      File.mkdir_p!(Path.join(work_dir, "gate-briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "briefs", "issue-42-engineer.md"]), "PROCEDURAL-BRIEF")

      File.write!(
        Path.join([work_dir, "gate-briefs", "issue-42-reviewer.md"]),
        "ATTENDU-CRITERIA"
      )

      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "docs"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])
      sha = String.trim(sha)

      body =
        "résumé\n\n" <>
          Fleet.Layout.brief_pointer_line("briefs/issue-42-engineer.md", sha) <>
          "\n" <> Fleet.Layout.criteria_pointer_line("gate-briefs/issue-42-reviewer.md", sha)

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # The criterion is not INLINED — it is a mounted file the judge reads (content-addressed). The
      # disambiguation (criteria over brief) now lives on the MOUNT SOURCE, not on a citation in the
      # order text: the mount resolves the criteria doc (`gate-briefs/`), never the producer's brief.
      assert brief =~ "~/issues/criteria.md"
      assert mount.ref == "gate-briefs/issue-42-reviewer.md"

      # transport_brief_v2 — the order text cites NO ops path and NO sha (pure pointer). Mutation-
      # verified: reinstating a ref citation in `mounted_mandate/3` reddens these refutes.
      refute brief =~ "gate-briefs/issue-42-reviewer.md"
      refute brief =~ "briefs/issue-42-engineer.md"
      refute brief =~ sha
      # Not inlined: the raw doc bodies do not travel in the order.
      refute brief =~ "ATTENDU-CRITERIA"
      refute brief =~ "PROCEDURAL-BRIEF"
    end

    @tag :tmp_dir
    test "no criteria pointer → the judge falls back to the brief (no regression)",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "briefs", "issue-42-engineer.md"]), "BRIEF-ONLY-CRITERION")
      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "brief"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])

      body =
        "résumé\n\n" <>
          Fleet.Layout.brief_pointer_line("briefs/issue-42-engineer.md", String.trim(sha))

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # Fallback: no criteria pointer → the mount resolves the brief doc (briefs/), the criterion of
      # last resort. The invariant lives on the mount source, not on the order text (which cites none).
      # The judge's file is ALWAYS named `criteria.md` — even when its content falls back to the brief.
      assert brief =~ "~/issues/criteria.md"
      assert mount.ref == "briefs/issue-42-engineer.md"
      assert mount.filename == "criteria.md"
      refute brief =~ "briefs/issue-42-engineer.md"
      refute brief =~ "BRIEF-ONLY-CRITERION"
    end

    @tag :tmp_dir
    test "build_brief SURFACES the mandate mount (4th element) — what every dispatch path materializes",
         %{tmp_dir: tmp} do
      # The bug the review found: the PR-judge dispatch rendered a brief that references
      # `~/issues/criteria.md` but never set `:mandate`, so nothing materialized it. The fix is that
      # build_brief RETURNS the mount source (from the SAME resolution that rendered the brief), so
      # no dispatch path can render the reference without also carrying what materializes it.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(Path.join(work_dir, "gate-briefs"))
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "h@l"])
      {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "H"])
      File.write!(Path.join([work_dir, "gate-briefs", "issue-42-reviewer.md"]), "L'ATTENDU")
      {_, 0} = System.cmd("git", ["-C", work_dir, "add", "."])
      {_, 0} = System.cmd("git", ["-C", work_dir, "commit", "-q", "-m", "criteria"])
      {sha, 0} = System.cmd("git", ["-C", work_dir, "rev-parse", "HEAD"])
      sha = String.trim(sha)

      body =
        "résumé\n\n" <>
          Fleet.Layout.criteria_pointer_line("gate-briefs/issue-42-reviewer.md", sha)

      assert {:ok, _brief, "judge", mount} =
               BriefBuilder.build_brief(
                 judge_profile(),
                 "reviewer",
                 StubForge,
                 "acme/widget",
                 42,
                 %{},
                 [_issue: {:ok, %{"body" => body}}],
                 {"pipe", "review"},
                 %{},
                 ops_root: tmp
               )

      # The mount names the criteria doc, its pinned sha, and the ops worktree the spawner archives.
      assert %{ref: "gate-briefs/issue-42-reviewer.md", sha: ^sha, ops_path: ops_path} = mount
      assert String.ends_with?(ops_path, "/widget")
    end
  end

  describe "build_brief — deliverable-judge, PREDECESSOR read (F-C083, l'autre moitié)" do
    # La règle était ÉNONCÉE pour le critère et VIOLÉE pour le prédécesseur, 35 lignes plus haut :
    # un `_ -> nil` écrasait `:none` (pas de prédécesseur, git-native légitime) et `{:error, _}`
    # (forge injoignable) dans la même branche. Ces tests tiennent la distinction.
    test "prédécesseur PRÉSENT → le payload est le livrable jugé" do
      assert {:ok, brief, "judge"} = build(_pred: {:ok, %{"livrable" => "PAYLOAD-XYZ"}})
      assert brief =~ "PAYLOAD-XYZ"
      refute brief =~ "git-native"
    end

    test "AUCUN prédécesseur (`:none`) → git-native : le CODE est le livrable, et c'est légitime" do
      assert {:ok, brief, "judge"} = build(_pred: :none)
      assert brief =~ "git-native"
    end

    test "prédécesseur VIDE (`{:ok, %{}}`) → git-native aussi : vide ≠ erreur" do
      assert {:ok, brief, "judge"} = build(_pred: {:ok, %{}})
      assert brief =~ "git-native"
    end

    test "READ-ERROR sur le prédécesseur → fail-closed, JAMAIS un juge sur la mauvaise matière" do
      # LE test qui discrimine. Avant le fix, cette lecture ratée tombait dans le git-native : le
      # juge notait le CODE de la branche au lieu du payload que son prédécesseur avait produit —
      # un verdict rendu sur autre chose, silencieusement, et indiscernable du cas légitime.
      assert {:error, {:criterion_unavailable, {:predecessor, :boom}}} =
               build(_pred: {:error, :boom})
    end
  end

  describe "rework brief — le feedback de review NON LU ne se tait pas" do
    defmodule ReworkForge do
      def change_request_feedback(_repo, _pr, opts), do: Keyword.get(opts, :_fb, {:ok, []})
    end

    defp rework(forge_opts),
      do:
        BriefBuilder.rework_brief(
          "engineer",
          ReworkForge,
          "acme/widget",
          7,
          forge_opts,
          nil,
          []
        )

    test "feedback PRÉSENT → les reviews sont dans le brief, nommées par leur auteur" do
      brief = rework(_fb: {:ok, [%{"login" => "reviewer-bot", "body" => "REVOIR-LE-NOMMAGE"}]})

      assert brief =~ "## Feedback de review à traiter (REQUEST_CHANGES)"
      assert brief =~ "reviewer-bot"
      assert brief =~ "REVOIR-LE-NOMMAGE"
    end

    test "AUCUN feedback (`{:ok, []}`) → silence : il n'y a rien à dire, et le dire serait du bruit" do
      brief = rework(_fb: {:ok, []})

      # Le gabarit dit « REQUEST_CHANGES » dans son intro quoi qu'il arrive : ce qui distingue les
      # trois cas est l'EN-TÊTE DE SECTION, pas le mot.
      refute brief =~ "## Feedback de review"
    end

    test "READ-ERROR → le brief DIT que les reviews existent et n'ont pas été lues" do
      # Le défaut : `{:ok, []}` et `{:error, _}` rendaient le MÊME brief. Le producteur retravaillait
      # à l'aveugle en croyant qu'on ne lui avait rien reproché — et repartait plausiblement avec le
      # même défaut, brûlant un cycle de review de plus. Ici on ne diffère pas (un producteur sans
      # son feedback travaille MOINS BIEN, il ne rend pas un faux verdict) : on rend le trou VISIBLE.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          brief = rework(_fb: {:error, :timeout})

          assert brief =~ "## Feedback de review — NON LU"
          assert brief =~ "Elles EXISTENT"
          refute brief =~ "## Feedback de review à traiter"
        end)

      # Le rail est celui de la FAÇADE dont ce module est extrait, pas son dernier segment.
      assert log =~ "StepDispatcher: rework feedback UNREADABLE"
      assert log =~ "timeout"
    end
  end

  describe "brief pointer (E4) — the ticket points at a ops-authored doc" do
    @moduletag :tmp_dir

    defp worker_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"brief_kind" => "worker"}
      }
    end

    defp build_worker(issue, opts) do
      case BriefBuilder.build_brief(
             worker_profile(),
             "engineer",
             StubForge,
             "acme/widget",
             42,
             issue,
             [],
             {"pipe", "build"},
             %{},
             opts
           ) do
        {:ok, brief, kind, _mount} -> {:ok, brief, kind}
        other -> other
      end
    end

    defp authored_workops(tmp) do
      # the project's ops = <ops_root>/widget with an authored brief committed.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE DOC COMPLET.\n", name_hint: "my-slug")

      {ref, sha}
    end

    test "pointer ticket → the PINNED doc becomes the brief (worker order carries the doc, not the pointer)",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_workops(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => body}, ops_root: tmp)

      # The order is a MOUNTED file the producer reads (content-addressed), not the doc inlined.
      assert brief =~ "~/issues/brief.md"
      refute brief =~ "LE DOC COMPLET."
      refute brief =~ "Brief: #{ref}"

      # transport_brief_v2 — the body is a PURE pointer: it names the mounted file and NOTHING of
      # the pin. The sha (and its 7-char prefix) is the runtime's to engrave, never the agent's to
      # relay. Mutation-verified: reinstating any sha citation in `mounted_mandate/3` reddens this.
      refute brief =~ sha
      refute brief =~ String.slice(sha, 0, 7)
      refute brief =~ "Source du brief"
    end

    test "unresolvable pointer (wrong sha) → DEFER via the criterion rail, never a guessed brief",
         %{tmp_dir: tmp} do
      {ref, _sha} = authored_workops(tmp)

      body =
        "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, String.duplicate("0", 40))

      assert {:error, {:criterion_unavailable, {:brief_pointer, _}}} =
               build_worker(%{"number" => 42, "body" => body}, ops_root: tmp)
    end

    test "no pointer → inline body IS the brief (both channels honest, same downstream)", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => "inline brief"}, ops_root: tmp)

      assert brief =~ "inline brief"

      # transport_brief_v2 — the inline order carries no source line at all: `brief_source_line/1`
      # is gone. An inline brief IS the order; there is no separate doc to cite.
      refute brief =~ "Source du brief"
    end
  end

  describe "deliverable-judge criterion — the gate-brief points at it, and cites no pin" do
    @describetag :tmp_dir

    defp authored_criterion(tmp) do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE CRITÈRE COMPLET.\n", name_hint: "crit")

      {ref, sha}
    end

    test "pointer ticket → the judge gets a PURE POINTER, no pin cited (the runtime engraves it)",
         %{
           tmp_dir: tmp
         } do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "judge", mount} =
               build4([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # THE CRITERION IS A MOUNTED FILE THE JUDGE READS, not inline text. The order references
      # `~/issues/criteria.md` (content-addressed) instead of carrying the doc body — so what the
      # judge acts on is exactly what was authored, read from the pin, nothing to trust.
      assert brief =~ "~/issues/criteria.md"
      refute brief =~ "LE CRITÈRE COMPLET."

      # transport_brief_v2 — the pin does NOT travel in the order text: neither ref nor sha (short or
      # full). It is the runtime's to engrave (commit message + forge), not the agent's to relay. The
      # address still travels OUT on the mount source, for the spawner — never into the order.
      refute brief =~ "#{ref}"
      refute brief =~ String.slice(sha, 0, 7)
      assert %{ref: ^ref, sha: ^sha} = mount

      # No payload may name that variable: naming it re-creates the need to mount ops.
      refute brief =~ "LCARS_PROJECT_OPS"
    end

    test "the criterion says read-and-evaluate — defused means do-not-execute, not do-not-read",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_criterion(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => body}}], ops_root: tmp)

      # It lands under "CONTEXT — already handled, DO NOT execute". A judge reading that as
      # do-not-read skips its only criterion, and a judge without a criterion APPROVES — the false
      # green this rail fail-closes against elsewhere. So both instructions are stated: read the
      # mounted criterion, do not execute it.
      assert brief =~ "DO NOT execute"
      assert brief =~ "ne l'exécute pas"
      assert brief =~ "lis-le"
    end

    test "INVERSE TWIN — an inline brief is still embedded: there is nothing to point at", %{
      tmp_dir: tmp
    } do
      assert {:ok, brief, "judge"} =
               build([_issue: {:ok, %{"body" => "CRITÈRE INLINE."}}], ops_root: tmp)

      assert brief =~ "CRITÈRE INLINE."
      refute brief =~ "LCARS_PROJECT_OPS"
    end
  end

  describe "conflict rework brief — one mechanic, two voices" do
    # The gatekeeper arrives on someone else's branch after the producer's budget ran out. Told
    # "ton brief est INCHANGÉ", it is being addressed as the author of work it never wrote, and
    # invited to guess at an intention it does not hold. The steps are the same; who is spoken to
    # is not — and nothing but this test keeps the two apart once they share a code path.
    defmodule ConflictForge do
      def change_request_feedback(_repo, _pr, _opts), do: {:ok, []}
    end

    # JG-137 — `base_branch` est desormais REQUIS sur les deux voix conflit : la procedure donnee a
    # l'agent nommait `main` en dur alors que la plomberie connaissait la vraie base depuis toujours
    # (`:pr_base_branch`, posee depuis `pr.base.ref`, et c'est deja elle qui choisit le worktree de
    # resolution). Sur une PR qui ne vise pas la face code, le brief etait INEXECUTABLE.
    defp conflict_brief(voice, base \\ "main") do
      BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil,
        conflict: voice,
        base_branch: base
      )
    end

    test "the PRODUCER is told its own brief is unchanged (it is resuming approved work)" do
      brief = conflict_brief(:producer)

      assert brief =~ "Ton brief est INCHANGÉ"
      assert brief =~ "l'intention de TON brief"
      refute brief =~ "Passe d'exception"
    end

    test "the OUTSIDER is told it has no brief, and must compose rather than pick a side" do
      # `:exception`, not `:gatekeeper`: the axis this voice turns on is OWNER vs OUTSIDER, and it
      # survived the role moving from the gatekeeper to `chief`. Naming the option after whoever
      # holds the capability is what made this voice look like a gatekeeper detail.
      brief = conflict_brief(:exception)

      assert brief =~ "Passe d'exception"
      assert brief =~ "tu n'as pas de brief à reprendre"
      assert brief =~ "tu ne choisis pas un camp"
      # The outsider must know that refusing IS the expected outcome when composing needs a
      # decision the code does not carry — a guessed resolution costs more than a motivated refusal.
      assert brief =~ "blocked"

      # And it must NEVER inherit the producer's framing.
      refute brief =~ "Ton brief est INCHANGÉ"
      refute brief =~ "TON brief"
    end

    # JG-137 — LA PROCEDURE DONNEE A L'AGENT NOMMAIT `main` EN DUR. La plomberie connaissait la vraie
    # base depuis toujours : `:pr_base_branch` est posee par `dispatch_review` depuis `pr.base.ref`,
    # et c'est deja elle qui choisit le worktree de resolution. Sur une PR qui ne vise pas la face
    # code, le producteur recevait donc une commande INEXECUTABLE — et s'il improvisait un
    # `fetch main`, il composait son livrable contre la mauvaise face.
    # ⚠ 6-135 — ET LE NOM CORRIGE NE SUFFISAIT PAS. JG-137 a mis la VRAIE base dans la commande ;
    # elle restait inexecutable, parce qu'un pod de review clone `--branch <head> --single-branch`
    # et que `origin/<base>` n'est pas dans son clone. Le defaut avait seulement change de raison.
    # La commande vise maintenant `lcars/base`, le ref rapatrie par le bootstrap ; la PROSE garde
    # le nom de la face, qui est ce qui dit au producteur contre quoi il compose.
    test "JG-137+6-135: les DEUX voix visent un ref qui EXISTE, et nomment la vraie base" do
      for voice <- [:producer, :exception] do
        brief = conflict_brief(voice, "workshop")

        assert brief =~ "git merge lcars/base",
               "voix #{voice} : la procedure vise un ref absent du clone d'un pod de review"

        assert brief =~ "workshop",
               "voix #{voice} : la procedure ne nomme plus la base reelle de la PR"

        refute brief =~ "git merge origin/",
               "voix #{voice} : une commande executable vise encore un `origin/<base>` inexistant"
      end
    end

    test "TEMOIN JG-137 — la base SUIT la PR, elle n'a pas juste change de nom" do
      # Sans ce temoin, un correctif qui remplacerait la base par n'importe quoi passerait le test
      # ci-dessus. Le ref executable est le meme dans les deux cas — c'est le POINT, il est
      # universel — donc le temoin porte la ou la difference doit se voir : la prose.
      assert conflict_brief(:producer, "main") =~ "divergé de `main`"
      assert conflict_brief(:producer, "workshop") =~ "divergé de `workshop`"
    end

    test "no conflict → no section at all (the default path is untouched)" do
      brief = BriefBuilder.rework_brief("engineer", ConflictForge, "fleet/x", 7, [], nil)

      refute brief =~ "Conflit de merge"
      refute brief =~ "Passe d'exception"
    end
  end

  describe "brief-judge (scoper) — mounts the brief it judges, cites no pin (transport_brief_v2)" do
    @describetag :tmp_dir

    defp scoper_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "scoper"},
        spec: %{"brief_kind" => "judge"}
      }
    end

    # The scoper reads `_brief_source` from the ENTRY resolution of the ISSUE (position 6), so the
    # pointer must live in the passed issue body, not in a forge fetch.
    defp build_scoper(issue_map, opts) do
      BriefBuilder.build_brief(
        scoper_profile(),
        "scoper",
        StubForge,
        "acme/widget",
        42,
        issue_map,
        [],
        {"brief-gate", "brief-review"},
        %{"judge_target" => "brief"},
        opts
      )
    end

    test "pointer ticket → the scoper SURFACES a mount and judges a mounted file, no text, no pin",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE BRIEF À JUGER.\n", name_hint: "brf")

      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "judge", mount} =
               build_scoper(%{"body" => body}, ops_root: tmp)

      # The scoper now READS a mounted file like every other pod — it used to inline the brief text
      # and cite the pin. Mutation-verified: returning `nil` as the mount source (the old behavior)
      # reddens this, and reinstating the inline `%{"brief" => brief, ...}` outputs reddens the
      # refutes below.
      assert %{ref: ^ref, sha: ^sha, filename: "brief.md"} = mount
      assert brief =~ "~/issues/brief.md"
      refute brief =~ "LE BRIEF À JUGER."
      refute brief =~ "#{ref}"
      refute brief =~ sha
      refute brief =~ String.slice(sha, 0, 7)
    end

    test "inline ticket (no pointer) → the brief IS the thing to judge, embedded, no mount",
         %{tmp_dir: tmp} do
      assert {:ok, brief, "judge", mount} =
               build_scoper(%{"body" => "brief inline à juger"}, ops_root: tmp)

      # Degraded/PoC: nothing pinned to mount → the body is embedded as before, and no mount travels.
      assert is_nil(mount)
      assert brief =~ "brief inline à juger"
      refute brief =~ "~/issues/brief.md"
    end
  end
end
