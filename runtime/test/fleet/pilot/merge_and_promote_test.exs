defmodule Fleet.Pilot.MergeAndPromoteTest do
  @moduledoc """
  Exercises merge/promotion through forge stubs and local Git provenance fixtures.
  Role credentials come from tmp_dir; synchronous execution protects shared config.
  Mailbox assertions observe requested calls, not durable forge state or feed order.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{CloseFailForge, MergeFailForge, OkForge}
  alias Fleet.Pilot.MergeAndPromote
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # Both role tokens are available; merge resolves its token before the attempt,
    # decision resolves its token only after merge.
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    TestEnv.put_role_token!("gatekeeper", "GK-TOKEN")
    TestEnv.put_role_token!("chief", "CHIEF-TOKEN")

    :ok
  end

  defmodule CommentFailForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  defmodule CloseFlakyForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}

    def close_issue(_r, n, _o) do
      attempt = (Process.get({:close_attempts, n}) || 0) + 1
      Process.put({:close_attempts, n}, attempt)
      send(self(), {:close_attempt, n, attempt})
      if attempt < 3, do: {:error, {:http, 500, "flaky"}}, else: {:ok, :closed}
    end
  end

  defmodule StageFlakyForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}

    def set_stage(_r, n, _s, _o) do
      attempt = (Process.get({:stage_attempts, n}) || 0) + 1
      Process.put({:stage_attempts, n}, attempt)
      send(self(), {:stage_attempt, n, attempt})
      if attempt < 3, do: {:error, {:http, 500, "flaky stage"}}, else: {:ok, :posted}
    end
  end

  test "DEUX RAILS : le merge signe chief, le commentaire et la fermeture signent gatekeeper" do
    forge_opts = [token: "system-token"]

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", forge_opts,
               base_branch: "main"
             )

    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "CHIEF-TOKEN"

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"

    assert c_opts[:token] == "GK-TOKEN"
    assert c_opts[:dedup_signature] == "[merge:pr-7]"
    assert c_opts[:dedup_any_author] == true

    assert_received {:close_issue, "fleet/p", 42, close_opts}
    assert close_opts[:token] == "GK-TOKEN"

    # WS1: stage/merged uses raw system options, including on the out-of-band path.
    assert_received {:set_stage, "fleet/p", 42, _stage, stage_opts}
    assert stage_opts[:token] == "system-token"
  end

  # Token assertions do not check prose: the interim note once assigned merge capability
  # to gatekeeper despite chief's actual merge token. Check the generated text too.
  test "la PROSE du sceau n'attribue jamais la fusion au gatekeeper — le banc l'a prise en défaut" do
    forge_opts = [token: "system-token"]

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", forge_opts,
               base_branch: "main"
             )

    assert_received {:comment, "fleet/p", 42, body, _opts}

    assert body =~ "rail merge"
    assert body =~ "rail décision"

    refute body =~ "habilité au merge"

    for phrase <- ["gatekeeper` (habilité", "gatekeeper fusionne", "gatekeeper` fusionne"] do
      refute body =~ phrase, "le sceau attribue la fusion au rail décision : #{inspect(phrase)}"
    end
  end

  test "merge KO → {:error, {:merge, _}} AND NO \"merged\" claim posted (no lie before reality)" do
    assert {:error, {:merge, {:http, 409, _}}} =
             MergeAndPromote.merge_and_promote(MergeFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:comment, _, _, _, _}
  end

  # Simulate an errored merge response followed by a readback reporting merged.
  defmodule TimeoutButMergedForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: {:error, {:http, :timeout, "reply cut mid-flight"}}
    def get_pull(_r, _pr, _o), do: {:ok, %{"merged" => true, "state" => "closed"}}

    def post_comment(r, n, b, o) do
      send(self(), {:comment, r, n, b, o})
      {:ok, :posted}
    end

    def set_stage(r, n, s, o) do
      send(self(), {:set_stage, r, n, s, o})
      {:ok, :posted}
    end

    def close_issue(r, n, o) do
      send(self(), {:close_issue, r, n, o})
      {:ok, :closed}
    end
  end

  defmodule TimeoutNotMergedForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def merge_pr(_r, _pr, _o), do: {:error, {:http, :timeout, "reply cut mid-flight"}}

    def get_pull(_r, _pr, _o),
      do: {:ok, %{"merged" => false, "state" => "open", "mergeable" => true}}

    def post_comment(r, n, b, o) do
      send(self(), {:comment, r, n, b, o})
      {:ok, :posted}
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  test "merge POST errors but the SERVER says merged → the seal CONVERGES its postconditions" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 MergeAndPromote.merge_and_promote(
                   TimeoutButMergedForge,
                   "fleet/p",
                   7,
                   42,
                   "engineer",
                   [token: "system-token"],
                   base_branch: "main"
                 )
      end)

    # These messages establish that comment, stage and close were requested.
    assert_received {:comment, "fleet/p", 42, body, _}
    assert body =~ "[merge:pr-7]"
    assert_received {:set_stage, "fleet/p", 42, _, _}
    assert_received {:close_issue, "fleet/p", 42, _}
    assert log =~ "SERVER says merged"
  end

  test "merge POST errors and the readback says NOT merged → error propagates, nothing posts" do
    assert {:error, {:merge, {:http, :timeout, _}}} =
             MergeAndPromote.merge_and_promote(
               TimeoutNotMergedForge,
               "fleet/p",
               7,
               42,
               "engineer",
               [token: "system-token"],
               base_branch: "main"
             )

    refute_received {:comment, _, _, _, _}
  end

  test "comment KO AFTER merge → :ok anyway (the merge counts, the lost trace is LOGGED, not silent)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 MergeAndPromote.merge_and_promote(
                   CommentFailForge,
                   "fleet/p",
                   7,
                   42,
                   "engineer",
                   [],
                   base_branch: "main"
                 )
      end)

    assert_received :merged
    assert log =~ "seal comment NOT posted"
  end

  test "F-C066: merge OK but close failed (persistent) → {:error, {:close_after_merge, _}}, NEVER a lying :ok" do
    assert {:error, {:close_after_merge, {:http, 500, "close boom"}}} =
             MergeAndPromote.merge_and_promote(CloseFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    refute_received {:close_attempt, 42}
  end

  test "CI-06: FLAKY stage/merged (fails 2×) → self-heals via retry, the load-bearing label lands, seal :ok" do
    assert :ok =
             MergeAndPromote.merge_and_promote(StageFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:stage_attempt, 42, 1}
    assert_received {:stage_attempt, 42, 2}
    assert_received {:stage_attempt, 42, 3}
    refute_received {:stage_attempt, 42, _}
  end

  test "F-C066: flaky close (fails 2×, succeeds the 3rd) → retry → :ok (self-heal of a transient blip)" do
    assert :ok =
             MergeAndPromote.merge_and_promote(CloseFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:close_attempt, 42, 1}
    assert_received {:close_attempt, 42, 2}
    assert_received {:close_attempt, 42, 3}
  end

  # Shared local Git fixtures: test/support/pilot/provenance_wall_harness.ex.
  alias Fleet.Test.ProvenanceWallHarness, as: Wall
  alias Fleet.Test.ProvenanceWallHarness.WallForge

  defp wall_harness(tmp), do: Wall.harness(tmp)
  defp wall_statement(tmp, issue_n, head, input), do: Wall.statement(tmp, issue_n, head, input)
  defp wall_opts(tmp, head), do: Wall.opts(tmp, head)

  @tag :requires_git
  test "provenance wall: an INCOHERENT statement REFUSES the merge (deterministic, no LLM)",
       %{tmp_dir: tmp} do
    %{head: head, alien: alien} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, alien)

    assert {:error, {:provenance_incoherent, {:base_not_ancestor, ^alien, ^head}}} =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    refute_received {:merge, _}
    assert_received {:comment, 4, body, "[provenance-wall:pr-4]"}
    assert body =~ "Provenance incohérente"
  end

  @tag :requires_git
  test "provenance wall: a COHERENT statement lets the seal proceed", %{tmp_dir: tmp} do
    %{base: base, head: head} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, base)

    assert :ok =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    assert_received {:merge, 4}
  end

  @tag :requires_git
  test "provenance wall: une preuve pour un AUTRE sha ne peut plus etre confondue avec la preuve de la brique (BL-6-43)",
       %{tmp_dir: tmp} do
    # This test checks SHA-keyed proof lookup only; it does not call the seal or
    # establish that a PR head cannot change between verification and merge.
    %{head: head, base: base, alien: alien} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, alien, base)

    proj = Path.join([tmp, "p", "demo"])

    assert {:ok, _} = Fleet.Workflow.Git.read_provenance(proj, alien)

    assert {:error, :no_provenance_ref} = Fleet.Workflow.Git.read_provenance(proj, head)
  end

  @tag :requires_git
  test "provenance wall SAUTÉ : le merge passe, ET la PR le DIT (BL-6-47.4)", %{tmp_dir: tmp} do
    %{head: head} = wall_harness(tmp)
    # No proof is written, so the wall skips with no_statement.

    assert :ok =
             MergeAndPromote.merge_and_promote(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    assert_received {:merge, 4}

    # Skipped and refused wall notes need distinct dedup signatures.
    assert_received {:comment, 4, body, "[provenance-wall-skipped:pr-4]"}
    assert body =~ "Provenance NON vérifiée"
    assert body =~ "no_statement"
    refute body =~ "Provenance incohérente"
  end

  defmodule ConflictForge do
    @moduledoc "A PR that went through a conflict: the chief round marker is on it."
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      if String.starts_with?(prefix, "[conflict-chief:pr-"), do: {:ok, 1}, else: {:ok, 0}
    end

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
  end

  defmodule SignalDownForge do
    @moduledoc "The conflict signal cannot be read — the seal must REFUSE, before any write."
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:error, {:http, 500, "boom"}}

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end
  end

  describe "A0 — the conflict signal picks the merge method" do
    test "no marker → method \"rebase\" (the historic behavior, byte-for-byte)" do
      assert :ok =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:merge, "fleet/p", 7, opts}
      assert Keyword.get(opts, :method) == "rebase"
    end

    test "un marqueur de conflit → méthode \"merge\", et le TEXTE le dit — la signature, elle, ne change pas" do
      # The token is chief on both paths; only the method changes for conflict markers.
      # Rebase could discard the merge commit carrying the resolution.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")

      assert :ok =
               MergeAndPromote.merge_and_promote(ConflictForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:merge, "fleet/p", 7, opts}
      assert Keyword.get(opts, :method) == "merge"
      assert Keyword.get(opts, :token) == "CHIEF-TOKEN"

      assert_received {:comment, "fleet/p", 42, body, _opts}
      assert body =~ "conflit résolu"
      refute body =~ "historique linéaire"
    end

    test "jeton du rail MERGE manquant → refus fail-closed, jamais un repli sur l'autre rail" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")
      TestEnv.delete_role_token!("chief")

      assert {:error, :role_token_unavailable} =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      refute_received {:merge, _, _, _}
      refute_received {:comment, _, _, _, _}
    end

    test "signal unreadable → seal REFUSED before any write (fail-loud, never a blind rebase)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:conflict_signal_unreadable, _}} =
                   MergeAndPromote.merge_and_promote(
                     SignalDownForge,
                     "fleet/p",
                     7,
                     42,
                     "engineer",
                     [],
                     base_branch: "main"
                   )
        end)

      refute_received {:merge, _, _, _}
      refute_received {:comment, _, _, _, _}
      assert log =~ "conflict signal UNREADABLE"
    end
  end

  # Probe evidence annotates the eventual comment; it is not a merge precondition.
  describe "A5 — le sceau constate si la tête a été sondée, et n'en fait jamais un mur" do
    defmodule JuryForge do
      @moduledoc false
      defdelegate count_comments_marked(r, n, p, o), to: OkForge
      defdelegate post_comment(r, n, b, o), to: OkForge
      defdelegate merge_pr(r, pr, o), to: OkForge
      defdelegate set_stage(r, n, s, o), to: OkForge
      defdelegate close_issue(r, n, o), to: OkForge
      defdelegate pr_refs(r, pr, o), to: OkForge
      def get_route(_r, _n, _o), do: :none

      def pr_review_state(_repo, _n, _opts),
        do:
          {:ok,
           %{
             verdicts: %{"fleet_qualifier" => :approved, "fleet_reviewer" => :approved},
             reviewers: ["fleet_qualifier", "fleet_reviewer"],
             outcome: :approved
           }}
    end

    # Signaled reads distinguish probed/unknown outcomes from paths that never queried.
    defmodule Probed do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:ok, true}
      end
    end

    defmodule Unprobed do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:ok, false}
      end
    end

    defmodule Unreadable do
      @moduledoc false
      def probed?(repo, sha, _opts) do
        send(self(), {:probed_asked, repo, sha})
        {:error, {:http, 503, "nope"}}
      end
    end

    defp seal_body(actions) do
      TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, actions)

      assert :ok =
               MergeAndPromote.merge_and_promote(JuryForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      assert_received {:comment, "fleet/p", 42, body, _}
      body
    end

    test "tête NON sondée + des juges → la mention est écrite, et le merge a quand même eu lieu" do
      body = seal_body(Unprobed)

      assert body =~ "Aucune sonde n'a tourné sur cette tête"

      assert_received {:merge, "fleet/p", 7, _}
      assert body =~ "livrée et fusionnée"
    end

    test "tête SONDÉE → la lecture a bien eu lieu, ET aucune ligne n'est écrite" do
      body = seal_body(Probed)

      assert_received {:probed_asked, "fleet/p", "deadbeef"}

      refute body =~ "Aucune sonde"
    end

    test "lecture IMPOSSIBLE → la question a été posée, et RIEN n'est affirmé" do
      body = seal_body(Unreadable)

      assert_received {:probed_asked, "fleet/p", "deadbeef"}

      refute body =~ "Aucune sonde"
    end

    test "zéro juge → rien n'est annoté, et la lecture de sonde n'est pas dépensée" do
      # Keep the signaling stub installed so refute distinguishes no read from a silent result.
      TestEnv.put_env_restoring(:lcars_fleet, :forge_actions, Unprobed)

      assert :ok =
               MergeAndPromote.merge_and_promote(OkForge, "fleet/p", 7, 42, "engineer", [],
                 base_branch: "main"
               )

      refute_received {:probed_asked, _repo, _sha}

      assert_received {:comment, "fleet/p", 42, body, _}
      refute body =~ "Aucune sonde"
    end
  end

  # Unlike direct rendering tests, these exercise a failed forge review read.
  # Its :unreadable result must not become the empty-approval zero-judge sentence.
  describe "jury ILLISIBLE — le sceau ne l'ecrit pas comme un zero-jure" do
    defmodule BlindJuryForge do
      @moduledoc false
      defdelegate count_comments_marked(r, n, p, o), to: OkForge
      defdelegate post_comment(r, n, b, o), to: OkForge
      defdelegate merge_pr(r, pr, o), to: OkForge
      defdelegate set_stage(r, n, s, o), to: OkForge
      defdelegate close_issue(r, n, o), to: OkForge
      def get_route(_r, _n, _o), do: :none

      def pr_review_state(_repo, _n, _opts), do: {:error, {:http, 503, "forge down"}}

      def pr_refs(repo, pr, opts) do
        send(self(), {:pr_refs_asked, repo, pr, opts})
        {:ok, %{head_sha: "deadbeef", head_ref: "feat", base_sha: "cafe", base_ref: "main"}}
      end
    end

    defp seal_with_blind_jury do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   MergeAndPromote.merge_and_promote(
                     BlindJuryForge,
                     "fleet/p",
                     7,
                     42,
                     "engineer",
                     [],
                     base_branch: "main"
                   )
        end)

      assert_received {:comment, "fleet/p", 42, body, _}
      {body, log}
    end

    test "le commentaire dit NON LU, et n'affirme NI juge NI zero-jure" do
      {body, _log} = seal_with_blind_jury()

      assert body =~ "NON LU"
      assert body =~ "n'a pas pu être obtenu de la forge"

      refute body =~ "aucun juge"
      refute body =~ "nominal"
      refute body =~ "**Avis de**"
    end

    test "le mur de provenance est rapporte a part, avec sa raison" do
      # This fixture skips the wall for no_head_branch. The renderer tests the passed
      # variant separately; the two observations must remain distinguishable.
      {body, _log} = seal_with_blind_jury()

      assert body =~ "le mur de provenance **n'a PAS tourné**"
      assert body =~ ":no_head_branch"

      refute body =~ "ni jury, ni provenance"
      assert body =~ "Rien n'atteste ce merge dans ce commentaire"
    end

    test "aucune lecture de sonde n'est depensee — il n'y a pas d'avis au-dessus a annoter" do
      {body, _log} = seal_with_blind_jury()

      refute_received {:pr_refs_asked, _repo, _pr, _opts}
      refute body =~ "Aucune sonde"
    end

    test "le journal porte le degrade — le ticket est pour l'humain, le log pour l'operateur" do
      {_body, log} = seal_with_blind_jury()

      assert log =~ "jury UNREADABLE at seal time"
      assert log =~ "fleet/p#42"
    end

    test "la lecture ratee n'empeche RIEN — la brique est fusionnee et le ticket ferme" do
      {_body, _log} = seal_with_blind_jury()

      assert_received {:merge, "fleet/p", 7, _}
      assert_received {:close_issue, "fleet/p", 42, _}
    end
  end
end
