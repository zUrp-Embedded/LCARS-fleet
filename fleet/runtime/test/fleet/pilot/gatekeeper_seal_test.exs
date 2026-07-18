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
  alias Fleet.Pilot.TestEnv

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

  test "signed merge THEN gatekeeper comment (internal as_gatekeeper signature) + dedup → :ok" do
    # RAW forge_opts (system token): the gatekeeper signature must be applied INTERNALLY by
    # `seal_and_merge` (single writer `as_gatekeeper`) — the role token OVERWRITES the system's.
    forge_opts = [token: "system-token"]
    assert :ok = GatekeeperSeal.seal_and_merge(OkForge, "fleet/p", 7, 42, "engineer", forge_opts)

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
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/p", 7, 42, "engineer", [])

    # THE crucial point (F-MERGE-CLAIM-BEFORE-REALITY): failed merge → we did NOT claim "delivered
    # and merged".
    refute_received {:comment, _, _, _, _}
  end

  # The merge is the act that counts; the comment is a post-merge trace DISCARDED WITHOUT LOG by
  # seal_and_merge — the readable trace is then missing on the issue and nothing re-posts it (the
  # dedup only guards against replays). Only the human trace is lost, never the merge.
  test "comment KO AFTER merge → :ok anyway (the merge counts, the trace is lost silently)" do
    assert :ok = GatekeeperSeal.seal_and_merge(CommentFailForge, "fleet/p", 7, 42, "engineer", [])

    assert_received :merged
  end

  test "F-C066: merge OK but close failed (persistent) → {:error, {:close_after_merge, _}}, NEVER a lying :ok" do
    # Core of the finding: returning `:ok` even when `close_issue` fails (log-loud then `:ok`) →
    # the caller believed the brick sealed while the issue stayed OPEN → re-dispatch →
    # double-delivery. Instead: HONEST typed return (the merge succeeded, but the close did not).
    assert {:error, {:close_after_merge, {:http, 500, "close boom"}}} =
             GatekeeperSeal.seal_and_merge(CloseFailForge, "fleet/p", 7, 42, "engineer", [])

    # BOUNDED retry: 3 close attempts before giving up (then honest return).
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    refute_received {:close_attempt, 42}
  end

  test "F-C066: flaky close (fails 2×, succeeds the 3rd) → retry → :ok (self-heal of a transient blip)" do
    assert :ok = GatekeeperSeal.seal_and_merge(CloseFlakyForge, "fleet/p", 7, 42, "engineer", [])

    assert_received {:close_attempt, 42, 1}
    assert_received {:close_attempt, 42, 2}
    assert_received {:close_attempt, 42, 3}
  end
end
