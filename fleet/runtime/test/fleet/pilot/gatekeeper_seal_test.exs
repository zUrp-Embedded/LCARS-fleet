defmodule Fleet.Pilot.GatekeeperSealTest do
  @moduledoc """
  SINGLE merge seal (F-arch-MCP): signed merge THEN signed gatekeeper comment. The merge is the
  source of truth — NEVER a "merged" claim before reality (F-MERGE-CLAIM-BEFORE-REALITY). The
  gatekeeper signature is applied INTERNALLY by `seal_and_merge` (`as_gatekeeper` → RoleToken): the
  gatekeeper account token comes from a controlled tmp_dir (never the runner's real
  `/home/private`). async: false (mutates the global `:role_tokens_dir` config).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{MergeFailForge, OkForge}
  alias Fleet.Pilot.GatekeeperSeal
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # Resolvable gatekeeper role token → `seal_and_merge` must sign merge AND comment with it.
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "GK-TOKEN")
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    :ok
  end

  defmodule CommentFailForge do
    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  # F-C066 — merge/comment/stage OK, close ALWAYS failing: proves the honest return (no lying :ok).
  defmodule CloseFailForge do
    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}

    def close_issue(_r, n, _o) do
      send(self(), {:close_attempt, n})
      {:error, {:http, 500, "close boom"}}
    end
  end

  # F-C066 — FLAKY close: fails 2×, succeeds the 3rd (process-dict counter) → proves self-heal via retry.
  defmodule CloseFlakyForge do
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

  # CI-06 — FLAKY stage/merged: fails 2×, succeeds the 3rd → proves the load-bearing projection self-heals
  # via its retry (mirror of the close retry). merge/comment/close all OK.
  defmodule StageFlakyForge do
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

  test "signed merge THEN gatekeeper comment (internal as_gatekeeper signature) + dedup → :ok" do
    # RAW forge_opts (system token): the gatekeeper signature must be applied INTERNALLY by
    # `seal_and_merge` (single writer `as_gatekeeper`) — the role token OVERWRITES the system's.
    forge_opts = [token: "system-token"]

    assert :ok =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/p", 7, 42, "engineer", forge_opts,
               base_branch: "main"
             )

    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "GK-TOKEN"

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"

    # gatekeeper-signed (role token, applied internally) + author-agnostic dedup (otherwise
    # double-post on retry).
    assert c_opts[:token] == "GK-TOKEN"
    assert c_opts[:dedup_signature] == "[merge:pr-7]"
    assert c_opts[:dedup_any_author] == true

    # Explicit close SIGNED GATEKEEPER (regression: it went out system-signed — identity break
    # inside the seal while merge+comment are ALREADY gatekeeper, cf. above).
    assert_received {:close_issue, "fleet/p", 42, close_opts}
    assert close_opts[:token] == "GK-TOKEN"
  end

  test "merge KO → {:error, {:merge, _}} AND NO \"merged\" claim posted (no lie before reality)" do
    assert {:error, {:merge, {:http, 409, _}}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # THE crucial point (F-MERGE-CLAIM-BEFORE-REALITY): failed merge → we did NOT claim "delivered
    # and merged".
    refute_received {:comment, _, _, _, _}
  end

  # The merge POST times out — but the SERVER committed the merge before the reply was cut.
  # The old seal skipped every postcondition on any merge error: the merged brick kept no
  # stage/merged, stayed open with an orphaned lock, and the reconciliation re-dispatched an
  # already-merged brick (double-delivery).
  defmodule TimeoutButMergedForge do
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

  # Same timeout, but the readback says the PR is NOT merged → the error must propagate
  # untouched (fail-closed), and nothing may post.
  defmodule TimeoutNotMergedForge do
    def merge_pr(_r, _pr, _o), do: {:error, {:http, :timeout, "reply cut mid-flight"}}

    def get_pull(_r, _pr, _o),
      do: {:ok, %{"merged" => false, "state" => "open", "mergeable" => true}}

    def post_comment(r, n, b, o), do: send(self(), {:comment, r, n, b, o}) && {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  test "merge POST errors but the SERVER says merged → the seal CONVERGES its postconditions" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 GatekeeperSeal.seal_and_merge(
                   TimeoutButMergedForge,
                   "fleet/p",
                   7,
                   42,
                   "engineer",
                   [token: "system-token"],
                   base_branch: "main"
                 )
      end)

    # The full postcondition queue ran from the readback proof: seal comment, stage/merged,
    # explicit close — the merged brick can neither stay open nor be re-dispatched.
    assert_received {:comment, "fleet/p", 42, body, _}
    assert body =~ "[merge:pr-7]"
    assert_received {:set_stage, "fleet/p", 42, _, _}
    assert_received {:close_issue, "fleet/p", 42, _}
    assert log =~ "SERVER says merged"
  end

  test "merge POST errors and the readback says NOT merged → error propagates, nothing posts" do
    assert {:error, {:merge, {:http, :timeout, _}}} =
             GatekeeperSeal.seal_and_merge(
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

  # The merge is the act that counts; the comment is a POST-merge trace, best-effort: a failed seal
  # comment does NOT block the seal (the merge stays authoritative), but it is LOGGED loud — nothing
  # re-posts it (the dedup only guards against replays), so the loss is visible in the log, never
  # silent. Only the human-readable trace is lost, never the merge.
  test "comment KO AFTER merge → :ok anyway (the merge counts, the lost trace is LOGGED, not silent)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 GatekeeperSeal.seal_and_merge(CommentFailForge, "fleet/p", 7, 42, "engineer", [],
                   base_branch: "main"
                 )
      end)

    assert_received :merged
    assert log =~ "seal comment NOT posted"
  end

  test "F-C066: merge OK but close failed (persistent) → {:error, {:close_after_merge, _}}, NEVER a lying :ok" do
    # Core of the finding: returning `:ok` even when `close_issue` fails (log-loud then `:ok`) →
    # the caller believed the brick sealed while the issue stayed OPEN → re-dispatch →
    # double-delivery. Instead: HONEST typed return (the merge succeeded, but the close did not).
    assert {:error, {:close_after_merge, {:http, 500, "close boom"}}} =
             GatekeeperSeal.seal_and_merge(CloseFailForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # BOUNDED retry: 3 close attempts before giving up (then honest return).
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    refute_received {:close_attempt, 42}
  end

  test "CI-06: FLAKY stage/merged (fails 2×) → self-heals via retry, the load-bearing label lands, seal :ok" do
    # Pre-CI-06 the set_stage failure was discarded UN-retried → the load-bearing `stage/merged` label
    # was lost on a transient blip → Delegation read `closed_without_merge` forever (arch waits on a
    # merged brick). Now retried (mirror of the close retry): a transient failure self-heals.
    assert :ok =
             GatekeeperSeal.seal_and_merge(StageFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:stage_attempt, 42, 1}
    assert_received {:stage_attempt, 42, 2}
    assert_received {:stage_attempt, 42, 3}
    refute_received {:stage_attempt, 42, _}
  end

  test "F-C066: flaky close (fails 2×, succeeds the 3rd) → retry → :ok (self-heal of a transient blip)" do
    assert :ok =
             GatekeeperSeal.seal_and_merge(CloseFlakyForge, "fleet/p", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:close_attempt, 42, 1}
    assert_received {:close_attempt, 42, 2}
    assert_received {:close_attempt, 42, 3}
  end

  # ── Provenance wall (Phase 2) — systematic, card-independent ──────────────
  defmodule WallForge do
    # branch_head exported → the wall RUNS (stubs without it exercise the skip path,
    # which every other test of this file proves).
    def branch_head(_repo, _branch, opts), do: {:ok, Keyword.fetch!(opts, :__head_sha__)}

    def post_comment(_r, n, body, o) do
      send(self(), {:comment, n, body, o[:dedup_signature]})
      {:ok, :posted}
    end

    def merge_pr(_r, pr, _o) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  defp wall_harness(tmp) do
    proj = Path.join([tmp, "p", "demo"])
    work = Path.join([tmp, "w", "demo"])
    File.mkdir_p!(proj)
    File.mkdir_p!(work)

    g = fn dir, args ->
      {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
      out
    end

    for dir <- [proj, work] do
      {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
      g.(dir, ["config", "user.email", "t@lcars.local"])
      g.(dir, ["config", "user.name", "t"])
    end

    File.write!(Path.join(proj, "f"), "base")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "base"])
    base = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    File.write!(Path.join(proj, "f"), "delivered")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "deliverable"])
    head = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    main = String.trim(g.(proj, ["rev-parse", "--abbrev-ref", "HEAD"]))
    g.(proj, ["checkout", "-q", "--orphan", "alien"])
    File.write!(Path.join(proj, "g"), "x")
    g.(proj, ["add", "."])
    g.(proj, ["commit", "-qm", "alien"])
    alien = String.trim(g.(proj, ["rev-parse", "HEAD"]))
    g.(proj, ["checkout", "-q", main])

    %{tmp: tmp, base: base, head: head, alien: alien}
  end

  defp wall_statement(tmp, issue_n, head, input) do
    work = Path.join([tmp, "w", "demo"])

    {:ok, _} =
      Fleet.Workflow.Provenance.emit(work, %{
        livrable_sha: head,
        input_sha: input,
        issue: issue_n
      })

    :ok
  end

  defp wall_opts(tmp, head) do
    [
      head_branch: "lcars/issue-9-engineer",
      projects_root: Path.join(tmp, "p"),
      work_root: Path.join(tmp, "w"),
      __head_sha__: head
    ]
  end

  test "provenance wall: an INCOHERENT statement REFUSES the merge (deterministic, no LLM)",
       %{tmp_dir: tmp} do
    %{head: head, alien: alien} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, alien)

    assert {:error, {:provenance_incoherent, {:base_not_ancestor, ^alien, ^head}}} =
             GatekeeperSeal.seal_and_merge(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    # THE point: nothing merged; the wall's user-facing trace is on the PR.
    refute_received {:merge, _}
    assert_received {:comment, 4, body, "[provenance-wall:pr-4]"}
    assert body =~ "Provenance incohérente"
  end

  test "provenance wall: a COHERENT statement lets the seal proceed", %{tmp_dir: tmp} do
    %{base: base, head: head} = wall_harness(tmp)
    :ok = wall_statement(tmp, 9, head, base)

    assert :ok =
             GatekeeperSeal.seal_and_merge(
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

  test "provenance wall SAUTÉ : le merge passe, ET la PR le DIT (BL-6-47.4)", %{tmp_dir: tmp} do
    # L'asymétrie fermée ici : les deux branches voisines loguaient, une seule écrivait SUR LA
    # FORGE. Une PR mergée avait donc exactement la même apparence, que le mur l'ait vérifiée ou
    # qu'il n'ait jamais tourné — « mergée » suggérait une provenance contrôlée. Le log ne rattrape
    # pas ça : la PR est l'artefact qu'un humain relit six mois plus tard, pas les journaux du BEAM.
    %{head: head} = wall_harness(tmp)
    # PAS de `wall_statement/4` → `{:skip, {:no_statement, ref}}`.

    assert :ok =
             GatekeeperSeal.seal_and_merge(
               WallForge,
               "fleet/demo",
               4,
               9,
               "engineer",
               wall_opts(tmp, head),
               Keyword.put(wall_opts(tmp, head), :base_branch, "main")
             )

    # Le merge n'est PAS bloqué — le chemin reste délibérément non-bloquant, le fix rend la
    # décision lisible, il ne la renverse pas.
    assert_received {:merge, 4}

    # Et la trace existe, sous une signature DISTINCTE de celle du refus : confondre les deux
    # ferait qu'une note « non vérifiée » dédupliquerait un vrai refus, ou l'inverse.
    assert_received {:comment, 4, body, "[provenance-wall-skipped:pr-4]"}
    assert body =~ "Provenance NON vérifiée"
    assert body =~ "no_statement"
    refute body =~ "Provenance incohérente"
  end
end
