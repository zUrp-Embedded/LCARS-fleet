defmodule Fleet.Pilot.ForgeClientTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.ForgeProtocol

  # Req stub Plug — intercepts requests in memory, no network.
  # Standard Req pattern (`:plug` option). All expected routes are
  # matched explicitly; a 500 fallback forces a test to make its
  # path explicit (no silent "any").
  defmodule FakeForge do
    @behaviour Plug

    @impl Plug
    def init(handlers), do: handlers

    @impl Plug
    def call(conn, handlers) do
      key = {conn.method, conn.request_path}

      case Map.fetch(handlers, key) do
        # Function handler (0-arity): response computed at call time → allows ORDERED responses on
        # a same path called multiple times (e.g. merge cascade FF→rebase, via a counter Agent).
        {:ok, fun} when is_function(fun, 0) ->
          {status, body} = fun.()

          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(status, JSON.encode!(body))

        {:ok, {status, body}} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(status, JSON.encode!(body))

        :error ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            500,
            JSON.encode!(%{error: "no handler for #{conn.method} #{conn.request_path}"})
          )
      end
    end
  end

  defp opts(handlers) do
    [
      base_url: "http://fake.test",
      token: "fake-token",
      req_options: [plug: {FakeForge, handlers}]
    ]
  end

  # Verdicts projection of `pr_review_state` — the standalone `pr_review_verdicts` projection was
  # nuked with its last production caller (get_issue_status now consumes the full state); these
  # tests keep exercising the same derivation (last-decisive, dismissed, commit-scoping) through
  # the surviving read.
  defp verdicts_of(repo, index, opts) do
    with {:ok, %{verdicts: verdicts}} <- ForgeClient.pr_review_state(repo, index, opts),
         do: {:ok, verdicts}
  end

  describe "repo_id/2 — the repo's forge id (source of truth for <REPO4>, BL-055)" do
    test "GET /repos/<repo> → {:ok, id} integer" do
      h = %{
        {"GET", "/api/v1/repos/fleet/lcars"} =>
          {200, %{"id" => 145, "full_name" => "fleet/lcars"}}
      }

      assert {:ok, 145} = ForgeClient.repo_id("fleet/lcars", opts(h))
    end

    test "nonexistent repo (404) → {:error, _} (the caller does not set a :repo_id — fail-loud mint)" do
      h = %{{"GET", "/api/v1/repos/fleet/ghost"} => {404, %{}}}
      assert {:error, _} = ForgeClient.repo_id("fleet/ghost", opts(h))
    end

    test "response without an id field → {:error, :no_id}" do
      h = %{{"GET", "/api/v1/repos/fleet/weird"} => {200, %{"full_name" => "fleet/weird"}}}
      assert {:error, :no_id} = ForgeClient.repo_id("fleet/weird", opts(h))
    end
  end

  describe "add_label/4 — happy paths" do
    test "adds the label by NAME (POST; Gitea resolves repo+org server-side)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "POST adds without touching existing labels (server-side preservation, no more GET-index/PUT-ids)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 3, "name" => "type:poc"}, %{"id" => 4, "name" => "state:open"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"id" => 3, "name" => "type:poc"},
             %{"id" => 4, "name" => "state:open"},
             %{"id" => 7, "name" => "lcars-dispatched"}
           ]}
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "no-op when the label is already present (zero write round-trip)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      # No PUT handler nor labels-index → if called, the 500 fallback
      # would crash. The test implicitly validates that we don't hit them.
      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — error paths" do
    test "unknown label (neither repo nor org) → the POST's HTTP error propagated" do
      # No client-side repo-id lookup anymore: an unknown name is decided by Gitea (failing POST).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {422, %{"message" => "label does not exist"}}
      }

      assert {:error, {:http, 422, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end

    test "non-2xx HTTP on GET issue labels (e.g. 404)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/9999/labels"} =>
          {404, %{"message" => "Not Found"}}
      }

      assert {:error, {:http, 404, _}} =
               ForgeClient.add_label("fleet/lcars", 9999, "lcars-dispatched", opts(handlers))
    end

    test "HTTP 401 on invalid token" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {401, %{"message" => "auth"}}
      }

      assert {:error, {:http, 401, _}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts(handlers))
    end
  end

  describe "add_label/4 — F-E5 self-heal (label absent from the forge)" do
    test "mute POST (unknown label, 200 WITHOUT the label) -> creates the repo label then re-adds -> :added" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # 1st POST: Gitea ignores the unknown name -> 200 WITHOUT the label (mute). 2nd POST
        # (after create): set.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => fn ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n == 0, do: {200, []}, else: {200, [%{"id" => 9, "name" => "lcars-awaits-arch"}]}
        end,
        # creation of the missing label at the REPO level (the self-heal)
        {"POST", "/api/v1/repos/fleet/lcars/labels"} => fn ->
          send(self(), :repo_label_created)
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
        end
      }

      assert {:ok, :added} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))

      # the label was created (repo) THEN the 2nd POST issue/labels set it (2 issue POSTs + 1 repo POST).
      assert_received :repo_label_created
      assert Agent.get(counter, & &1) == 2
    end

    test "label still absent even after creation -> fail-loud {:label_not_added} (never a lying :ok)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        # mute POST EVERY time (the label never sticks) -> no silent loop, we surface.
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/labels"} =>
          {201, %{"id" => 9, "name" => "lcars-awaits-arch"}}
      }

      assert {:error, {:label_not_added, "lcars-awaits-arch"}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-awaits-arch", opts(handlers))
    end
  end

  describe "list_open_issues/2" do
    test "returns all open issues WITHOUT filter (repo lease: in-flight included)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {200,
           [
             %{"number" => 1, "labels" => []},
             %{"number" => 2, "labels" => [%{"name" => "lcars-in-flight"}]}
           ]}
      }

      assert {:ok, [%{"number" => 1}, %{"number" => 2}]} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end

    test "propagates HTTP errors" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} =>
          {503, %{"message" => "Service Unavailable"}}
      }

      assert {:error, {:http, 503, _}} =
               ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
    end

    # MA-20 — a 2xx page of UNEXPECTED shape (non-list, e.g. a 200 error object, or a response
    # truncated by a proxy) must NOT return `{:ok, []}` (a silent empty the poller reads as
    # "nothing to dispatch"): the collection cannot be derived →
    # `{:error, {:unexpected_page_shape, …}}`.
    test "MA-20 — non-list 2xx page → {:error, :unexpected_page_shape}, NOT {:ok, []}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, %{"message" => "this is not a list"}}
      }

      result = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))

      assert {:error, {:unexpected_page_shape, path, page, %{"message" => _}}} = result
      assert page == 1
      assert is_binary(path) and String.contains?(path, "/issues")
      # Anti-regression guard: above all NOT a lying empty success.
      refute match?({:ok, []}, result)
    end
  end

  describe "list_org_repos/2 (WS3 discovery — org-membership = admission)" do
    test "nominal: list of repos → full_names (entries without full_name are discarded)" do
      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} =>
          {200, [%{"full_name" => "fleet/lcars"}, %{"full_name" => "fleet/demo"}, %{"id" => 3}]}
      }

      assert {:ok, ["fleet/lcars", "fleet/demo"]} =
               ForgeClient.list_org_repos("fleet", opts(handlers))
    end

    # Regression acte4 #9 — THE discovery collection reader coerced a non-list 2xx via `List.wrap`
    # → silent `{:ok, []}` = the poller believes "no repo" with no trace, exactly the false-green
    # MA-20 hunted on paginate. Since DR-016, the discovery PAGINATES via `paginate/3`: the
    # fail-loud guard is now the primitive's (`:unexpected_page_shape`), same doctrine.
    test "acte4 #9: non-list 2xx → {:error, :unexpected_page_shape}, NOT {:ok, []}" do
      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} => {200, %{"message" => "this is not a list"}}
      }

      result = ForgeClient.list_org_repos("fleet", opts(handlers))

      assert {:error, {:unexpected_page_shape, _path, _page, %{"message" => _}}} = result
      # Anti-regression guard: above all NOT a lying empty success.
      refute match?({:ok, []}, result)
    end
  end

  describe "list_open_pulls/2 + get_pull/3 (PR-driven judge dispatch)" do
    test "hybrid: /issues?type=pulls (filtered numbers) THEN get_pull (full PR shape)" do
      handlers = %{
        # #5.2 D1 — the listing goes through /issues (forge-side assignee filter), returns an issue
        # shape (numbers).
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => {200, [%{"number" => 6}]},
        # then get_pull fetches the real PR shape (head/requested_reviewers).
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6"} =>
          {200,
           %{
             "number" => 6,
             "head" => %{"ref" => "lcars/issue-999-engineer"},
             "requested_reviewers" => [%{"login" => "Qualifier"}],
             "labels" => []
           }}
      }

      assert {:ok, [%{"number" => 6, "head" => %{"ref" => "lcars/issue-999-engineer"}}]} =
               ForgeClient.list_open_pulls("fleet/lcars", opts(handlers))
    end

    test "get_pull/3: GET a single PR → full shape" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6"} =>
          {200, %{"number" => 6, "head" => %{"ref" => "lcars/issue-9-engineer", "sha" => "abc"}}}
      }

      assert {:ok, %{"number" => 6, "head" => %{"sha" => "abc"}}} =
               ForgeClient.get_pull("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): last decisive review per reviewer (login↓ → verdict)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_REVIEW",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => false
             },
             %{"state" => "COMMENT", "user" => %{"login" => "Reviewer"}, "dismissed" => false},
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false},
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "dismissed" => false
             }
           ]}
      }

      # Qualifier=APPROVED, Reviewer=REQUEST_CHANGES (COMMENT/REQUEST_REVIEW non-decisive, ignored).
      assert {:ok, %{"qualifier" => :approved, "reviewer" => :changes_requested}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): dismissed reviews ignored" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => true
             },
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false}
           ]}
      }

      # the dismissed REQUEST_CHANGES is ignored → Qualifier = APPROVED (their last active one).
      assert {:ok, %{"qualifier" => :approved}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): no decisive review -> %{}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200, [%{"state" => "REQUEST_REVIEW", "dismissed" => false}, %{"state" => "COMMENT"}]}
      }

      assert {:ok, %{}} = verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): a re-review OVERWRITES the same reviewer's older one (②.1d, last active)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # 1st round: qualifier rejects (then dismissed when re-reviewing), reviewer approves
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Qualifier"},
               "dismissed" => true
             },
             %{"state" => "APPROVED", "user" => %{"login" => "Reviewer"}, "dismissed" => false},
             # after rework: qualifier re-approves -> their LAST active one wins
             %{"state" => "APPROVED", "user" => %{"login" => "Qualifier"}, "dismissed" => false}
           ]}
      }

      assert {:ok, %{"qualifier" => :approved, "reviewer" => :approved}} =
               verdicts_of("fleet/lcars", 6, opts(handlers))
    end

    test "verdicts (pr_review_state): head_sha → a REQUEST_CHANGES on an OLD commit is stale (live #7)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # the reviewer rejected the OLD commit (never dismissed by Gitea on push) → stale on head
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # the qualifier approved the CURRENT commit → only valid verdict
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Qualifier"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      # Reviewer DISAPPEARS from the map (stale verdict) → will be `pending` → re-judged.
      # Qualifier stays.
      assert {:ok, %{"qualifier" => :approved}} =
               verdicts_of(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
    end

    test "verdicts (pr_review_state): head_sha → a re-review on head OVERWRITES the same judge's stale verdict" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
          {200,
           [
             # round 1: the reviewer rejects the old commit
             %{
               "state" => "REQUEST_CHANGES",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "old00000",
               "dismissed" => false
             },
             # round 2: the reviewer re-judges the current commit → approves (their LAST on head wins)
             %{
               "state" => "APPROVED",
               "user" => %{"login" => "Reviewer"},
               "commit_id" => "head1111",
               "dismissed" => false
             }
           ]}
      }

      assert {:ok, %{"reviewer" => :approved}} =
               verdicts_of(
                 "fleet/lcars",
                 6,
                 opts(handlers) ++ [head_sha: "head1111"]
               )
    end
  end

  describe "F-C069 — non-list 2xx on /reviews → fail-loud (paginate twin), never an {:ok, empty}" do
    # A 2xx with a NON-LIST body (proxy/gateway returning an HTML page or an object envelope with
    # 200) fell on `{:ok, _non_list} -> {:ok, <empty>}` → silently EMPTY jury/feedback/budget. The
    # twin `pr_rerequested_reviewers` (via `paginate`) fails loud `:unexpected_page_shape` on a
    # non-list page. We align → `{:error, {:unexpected_review_shape, path, body}}`. Consequences
    # avoided: merge on an empty jury (pr_review_state → dispatch_by_verdicts([], %{}) → MERGE
    # branch); undercounted rework budget (count → 0 → blind re-dispatch instead of arch
    # escalation).
    setup do
      %{
        handlers: %{
          {"GET", "/api/v1/repos/fleet/lcars/pulls/6/reviews"} =>
            {200, %{"message" => "internal proxy error (200 but not an array)"}}
        }
      }
    end

    test "pr_review_state: non-list 2xx → {:error, {:unexpected_review_shape, _, _}}", %{
      handlers: handlers
    } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.pr_review_state("fleet/lcars", 6, opts(handlers))
    end

    test "change_request_feedback: non-list 2xx → {:error, {:unexpected_review_shape, _, _}}",
         %{
           handlers: handlers
         } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.change_request_feedback("fleet/lcars", 6, opts(handlers))
    end

    test "count_change_request_rounds: non-list 2xx → {:error, ...} (NOT an undercounting {:ok, 0})",
         %{
           handlers: handlers
         } do
      assert {:error, {:unexpected_review_shape, _path, _body}} =
               ForgeClient.count_change_request_rounds("fleet/lcars", 6, opts(handlers))
    end
  end

  describe "add_label/4 — config" do
    test "missing base_url → {:error, {:config, {:missing, :base_url}}}" do
      assert {:error, {:config, {:missing, :base_url}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", token: "t")
    end

    @tag :tmp_dir
    test "token read from token_file (trims newline)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "gitea_token")
      File.write!(path, "secret-token-from-file\n")

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "absent token_file → {:error, {:config, {:token_file, _, :enoent}}}",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent_token")

      opts = [base_url: "http://fake.test", token_file: path]

      assert {:error, {:config, {:token_file, ^path, :enoent}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    @tag :tmp_dir
    test "F-031: EMPTY token_file → config error (no HTTP request, no late 401)",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_token")

      # file present but whitespace-only → trim yields "" → header `authorization: token ` (late 401).
      File.write!(path, "  \n\t")

      # NO handler: if an HTTP request went out anyway, the FakeForge 500 fallback → asserting on
      # the config error (never {:http, _, _}) proves we decide BEFORE the network round-trip.
      opts = [
        base_url: "http://fake.test",
        token_file: path,
        req_options: [plug: {FakeForge, %{}}]
      ]

      assert {:error, {:config, {:token_file_empty, ^path}}} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end

    test "trims trailing slash on base_url" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 7, "name" => "lcars-dispatched"}]}
      }

      opts = [
        base_url: "http://fake.test/",
        token: "t",
        req_options: [plug: {FakeForge, handlers}]
      ]

      assert {:ok, :already_present} =
               ForgeClient.add_label("fleet/lcars", 42, "lcars-dispatched", opts)
    end
  end

  # ============================================================
  # Write-ops (end-of-step-run primitives, DN forge-state-machine §5)
  # ============================================================

  describe "set_assignee/4" do
    test "PATCHes the assignee when different" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Engineer"}]}},
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{}}
      }

      assert {:ok, :set} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end

    test "no-op when already the sole assignee (idempotent)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42"} =>
          {200, %{"assignees" => [%{"login" => "Qualifier"}]}}
      }

      assert {:ok, :already} =
               ForgeClient.set_assignee("fleet/lcars", 42, "Qualifier", opts(handlers))
    end
  end

  # #5.2 D4 — `describe "set_state_label/4"` removed: the function is gone (state = route-comment,
  # no more `state:*` label).

  describe "post_comment/4 — signature dedup" do
    # `forge_bot_login` seam injected → deterministic (no GET /user nor persistent_term cache).
    defp dedup_opts(handlers, sig) do
      opts(handlers)
      |> Keyword.merge(dedup_signature: sig, forge_bot_login: "lcars-bot")
    end

    test "posts when the signature is absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {200, []},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 1}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    test "no-op when the signature already exists in a SYSTEM comment (idempotent replay)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "lcars-bot"},
               "body" => "already there [step_run:engineer:abc] livrable"
             }
           ]}
      }

      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    test "F058 review follow-up: signature pre-posted by an ATTACKER → the system posts anyway" do
      # a forge user posts the signature in advance; the dedup must NOT take it for a system write
      # (otherwise the system comment is dropped → count_signed_step_runs undercounts).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "attacker"}, "body" => "[step_run:engineer:abc] forged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 2}}
      }

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 dedup_opts(handlers, "[step_run:engineer:abc]")
               )
    end

    test "F058-bis: signature forged by an attacker + UNRESOLVED bot → the system posts anyway (fail-closed)" do
      # Soft fallback #7: unresolved bot → `{:error} -> comments` (trust ALL authors) → the forged
      # sig is taken as "already posted" → the system marker DROPPED (count_signed_step_runs
      # undercounts the anti-runaway budget). Fail-closed: unresolved bot → trust NOBODY → forged
      # sig not believed → the marker IS posted ("at worst a double-post", never a silent drop —
      # like the paginate-error case).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "attacker"}, "body" => "[step_run:engineer:abc] forged"}]},
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/comments"} => {201, %{"id" => 3}}
      }

      # UNRESOLVED bot injected via the error seam → deterministic, async-safe (no persistent_term).
      post_opts =
        opts(handlers)
        |> Keyword.merge(
          dedup_signature: "[step_run:engineer:abc]",
          forge_bot_login: {:error, :unresolved}
        )

      assert {:ok, :posted} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "[step_run:engineer:abc] livrable",
                 post_opts
               )
    end

    test "dedup_any_author: a signed ROLE comment (non-bot, e.g. Gatekeeper) → no-op (merge seal)" do
      # F-arch-MCP: the `[merge:pr-N]` seal is posted by the GATEKEEPER role account (not the bot)
      # → the bot-only dedup would miss it → double-post on retry. `dedup_any_author` makes it
      # author-agnostic (safe: `[merge:pr-N]` is NOT a counted marker, unlike `[step_run:role:sha]`
      # which F058 protects).
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [%{"user" => %{"login" => "Gatekeeper"}, "body" => "## ✅ Brique #42 [merge:pr-2]"}]}
      }

      # Without `dedup_any_author`, the Gatekeeper (non-bot) comment would be ignored → re-post
      # (cf. F058 test).
      assert {:ok, :already} =
               ForgeClient.post_comment(
                 "fleet/lcars",
                 42,
                 "## ✅ Brique #42 [merge:pr-2]",
                 dedup_opts(handlers, "[merge:pr-2]") |> Keyword.put(:dedup_any_author, true)
               )
    end
  end

  describe "remove_label/4 + close_issue/3" do
    test "remove_label: no-op when absent" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} => {200, []}
      }

      assert {:ok, :already_absent} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "remove_label: DELETE when present" do
      handlers = %{
        # the id (9) comes from the ATTACHED labels (GET issue labels), not a repo index → works
        # for org labels too.
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"id" => 9, "name" => "lcars-in-flight"}]},
        {"DELETE", "/api/v1/repos/fleet/lcars/issues/42/labels/9"} => {204, %{}}
      }

      assert {:ok, :removed} =
               ForgeClient.remove_label("fleet/lcars", 42, "lcars-in-flight", opts(handlers))
    end

    test "close_issue: PATCH state closed" do
      handlers = %{
        {"PATCH", "/api/v1/repos/fleet/lcars/issues/42"} => {201, %{"state" => "closed"}}
      }

      assert {:ok, :closed} = ForgeClient.close_issue("fleet/lcars", 42, opts(handlers))
    end
  end

  # Gitea-native time-tracking (stopwatch) — global mechanics wired at the same points as the
  # lcars-in-flight lock (spawn_step/unlock/reconciliation). 409 in both directions (already
  # active / nothing to stop) is idempotent — never a blocking error (cf. ForgeClient moduledoc
  # § Time-tracking).
  describe "start_stopwatch/3 + stop_stopwatch/3" do
    test "start: 201 -> :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/start"} => {201, %{}}
      }

      assert :ok = ForgeClient.start_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "start: 409 (already active, rebrief on a live pod) -> idempotent :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/start"} =>
          {409, %{"message" => "cannot start a stopwatch again if it already exists"}}
      }

      assert :ok = ForgeClient.start_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: 201 -> :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} => {201, %{}}
      }

      assert :ok = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: 409 (no active stopwatch) -> idempotent :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} =>
          {409, %{"message" => "cannot stop a non-existent stopwatch"}}
      }

      assert :ok = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end

    test "stop: real error (500) surfaces, NOT swallowed" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/lcars/issues/42/stopwatch/stop"} => {500, %{}}
      }

      assert {:error, _} = ForgeClient.stop_stopwatch("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "count_signed_step_runs/3 — round-trip with ForgeProtocol.step_run_marker" do
    test "counts a marker produced by ForgeProtocol.step_run_marker (format recognized end-to-end)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{
               "user" => %{"login" => "bot"},
               "body" => ForgeProtocol.step_run_marker("engineer", "deadbeef")
             }
           ]}
      }

      assert {:ok, 1} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "bot")
               )
    end
  end

  # ============================================================
  # get_route reads the POSITION from the SCOPED labels `wfmap/<map>` + `stage/<step>` (no longer a
  # `[lcars-route:...]` comment). The map comes from the DATA (wfmap label), NOT a coded default:
  # two issues may follow two maps. One of the two missing → `:none` (no invented map). Trust comes
  # from the WS1 write lock (only lcars-system sets the labels), not a read-time filter.
  # ============================================================
  describe "get_route/3 — via wfmap/* + stage/* labels" do
    test "wfmap/brief-gate + stage/build → {:ok, {\"brief-gate\", \"build\"}}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200,
           [
             %{"name" => "lcars-in-flight"},
             %{"name" => "wfmap/brief-gate"},
             %{"name" => "stage/build"}
           ]}
      }

      assert {:ok, {"brief-gate", "build"}} =
               ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test "the map comes from the DATA: wfmap/gkchain + stage/review → {:ok, {\"gkchain\", \"review\"}}" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "wfmap/gkchain"}, %{"name" => "stage/review"}]}
      }

      assert {:ok, {"gkchain", "review"}} =
               ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test "stage/* without wfmap/* (half-state) → :none (no map invented)" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "stage/build"}]}
      }

      assert :none = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end

    test "no position label (only flat locks) → :none" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/labels"} =>
          {200, [%{"name" => "lcars-in-flight"}, %{"name" => "lcars-awaits-arch"}]}
      }

      assert :none = ForgeClient.get_route("fleet/lcars", 42, opts(handlers))
    end
  end

  describe "count_signed_step_runs/3 — author-trust (F059)" do
    test "only counts step_runs signed by the bot" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:engineer:aaa]"},
             %{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:qualifier:bbb]"},
             %{
               "user" => %{"login" => "attacker"},
               "body" => "[step_run:fake:ccc] [step_run:fake:ddd]"
             }
           ]}
      }

      assert {:ok, 2} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  describe "get_predecessor_result/3 — author-trust (F060)" do
    test "only extracts the result block from a bot comment" do
      bot_body =
        "Livrable.\n\n```result\n" <> ~s({"severity_max":"ok"}) <> "\n```\n[step_run:a:1]"

      evil_body = "```result\n" <> ~s({"severity_max":"INJECTED"}) <> "\n```"

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200,
           [
             %{"user" => %{"login" => "lcars-bot"}, "body" => bot_body},
             %{"user" => %{"login" => "attacker"}, "body" => evil_body}
           ]}
      }

      assert {:ok, %{"severity_max" => "ok"}} =
               ForgeClient.get_predecessor_result(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end
  end

  # ⚠ persistent_term + async (F058 review follow-up #1): `derive_bot_login` caches the login in
  # `:persistent_term.{Fleet.Pilot.ForgeClient.Transport, :bot_login}` — a GLOBAL key shared by the
  # whole ExUnit VM (the /user derivation lives in the Transport module). ANY test that does NOT
  # inject `:forge_bot_login` in its opts reaches this cache and may pollute/be polluted by a
  # concurrent test. Module invariant: all OTHER tests inject the `forge_bot_login:` seam on
  # purpose (deterministic, no cache); ONLY the test below touches the cache, and it erases it
  # both upfront AND in `after`. A future seam-less test MUST do the same (or async:false).
  describe "forge_bot_login — /user derivation (seam absent)" do
    test "derives the login via GET /user when neither opts nor config" do
      handlers = %{
        {"GET", "/api/v1/user"} => {200, %{"login" => "derived-bot"}},
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} =>
          {200, [%{"user" => %{"login" => "derived-bot"}, "body" => "done [step_run:a:1]"}]}
      }

      # persistent_term cache: erased upfront for a deterministic test.
      :persistent_term.erase({Fleet.Pilot.ForgeClient.Transport, :bot_login})

      # get_route no longer derives (reads a label): we exercise the /user derivation via
      # count_signed_step_runs (which still filters bot-authored step_runs → needs the bot-login).
      assert {:ok, 1} = ForgeClient.count_signed_step_runs("fleet/lcars", 42, opts(handlers))
    after
      :persistent_term.erase({Fleet.Pilot.ForgeClient.Transport, :bot_login})
    end
  end

  describe "open_pr/5 + get_pr_for_branch/4 (BL-044 PR primitives)" do
    test "opens a PR head→base → {:ok, number}" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls"} => {201, %{"number" => 7}}}

      assert {:ok, 7} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "title", opts(handlers))
    end

    test "idempotent: 409 (PR already open) → finds the existing head→base PR" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls"} => {409, %{"message" => "already exists"}},
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200,
           [
             %{"number" => 3, "head" => %{"ref" => "other"}, "base" => %{"ref" => "main"}},
             %{"number" => 9, "head" => %{"ref" => "feature/x"}, "base" => %{"ref" => "main"}}
           ]}
      }

      assert {:ok, 9} =
               ForgeClient.open_pr("fleet/proj", "feature/x", "main", "title", opts(handlers))
    end

    test "get_pr_for_branch: no open head→base PR → :pr_not_found" do
      handlers = %{
        {"GET", "/api/v1/repos/fleet/proj/pulls"} =>
          {200, [%{"number" => 3, "head" => %{"ref" => "other"}, "base" => %{"ref" => "main"}}]}
      }

      assert {:error, :pr_not_found} =
               ForgeClient.get_pr_for_branch("fleet/proj", "feature/x", "main", opts(handlers))
    end
  end

  describe "protect_branch/3 (onboarding: forge-enforced gate)" do
    test "protect_branch → POST branch_protections, :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {201, %{"branch_name" => "main"}}
      }

      rule = %{rule_name: "main", required_approvals: 2, dismiss_stale_approvals: true}
      assert :ok = ForgeClient.Repo.protect_branch("fleet/proj", rule, opts(handlers))
    end

    test "protect_branch idempotent: rule already set (422) → :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branch_protections"} =>
          {422, %{"message" => "branch protection already exists"}}
      }

      assert :ok =
               ForgeClient.Repo.protect_branch("fleet/proj", %{rule_name: "main"}, opts(handlers))
    end
  end

  describe "request_review/4 + post_review/5 (trigger + verdict home)" do
    test "request_review → POST requested_reviewers, :ok" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/requested_reviewers"} => {201, [%{"id" => 1}]}
      }

      assert :ok = ForgeClient.request_review("fleet/proj", 9, ["Qualifier"], opts(handlers))
    end

    test "post_review :approve posts the verdict, :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/reviews"} => {200, %{"id" => 5}}}

      assert :ok = ForgeClient.post_review("fleet/proj", 9, :approve, "gate PASS", opts(handlers))
    end

    test "post_review unknown event → fail-loud without an HTTP round-trip" do
      assert {:error, {:invalid_review_event, :bogus}} =
               ForgeClient.post_review("fleet/proj", 9, :bogus, "x", opts(%{}))
    end
  end

  describe "create_branch/4 (feed-honest branch birth — one action)" do
    test "201 → :ok" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/branches"} => {201, %{"name" => "b"}}}

      assert :ok = ForgeClient.create_branch("fleet/proj", "lcars/issue-9-eng", "cafe", opts(handlers))
    end

    test "409 (already born — replay) → {:error, :branch_exists}, typed for the idempotent skip" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/branches"} =>
          {409, %{"message" => "branch already exists"}}
      }

      assert {:error, :branch_exists} =
               ForgeClient.create_branch("fleet/proj", "b", "cafe", opts(handlers))
    end

    test "other HTTP error propagates as-is (caller decides the fallback)" do
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/branches"} => {404, %{"message" => "no ref"}}}

      assert {:error, {:http, 404, _}} =
               ForgeClient.create_branch("fleet/proj", "b", "dead", opts(handlers))
    end
  end

  describe "merge_pr/3 (PROMOTE — single-call rebase + transient retry)" do
    # ORDERED responses on the merge path (called again on retry) via a counter Agent.
    defp seq_handler(responses) do
      {:ok, agent} = Agent.start_link(fn -> responses end)

      fn ->
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {{500, %{"message" => "sequence exhausted"}}, []}
        end)
      end
    end

    # 0 delay in tests → no real Process.sleep.
    defp merge_opts(handlers), do: [{:merge_retry_delay_ms, 0} | opts(handlers)]

    # Post-merge handlers (GET head.ref → DELETE branch): every merge-OK path runs the spaced
    # branch-delete tail — stubbing it keeps these tests warning-free (its failure path has its
    # own dedicated test below).
    defp post_merge_handlers do
      %{
        {"GET", "/api/v1/repos/fleet/proj/pulls/9"} =>
          {200, %{"head" => %{"ref" => "lcars/issue-9-eng"}}},
        {"DELETE", "/api/v1/repos/fleet/proj/branches/lcars%2Fissue-9-eng"} => {204, %{}}
      }
    end

    test "rebase succeeds first try → :ok" do
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}
        })

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "transient \"try again later\" (405) THEN 200 → retry → :ok (mergeability being computed, live morse)" do
      # 1st POST → 405 checking; 2nd POST (retry) → 200 (mergeability stabilized).
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
            seq_handler([{405, %{"message" => "Please try again later"}}, {200, %{}}])
        })

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "persistent \"try again later\" (3×405) → fail-loud {:http, 405, _} (bounded retry)" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}},
            {405, %{"message" => "Please try again later"}}
          ])
      }

      assert {:error, {:http, 405, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "NON-transient error (409 conflict) → IMMEDIATE fail-loud, no retry" do
      # Single element in the sequence: an attempted retry would yield 500 (exhausted) → asserting
      # on 409 proves it.
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{409, %{"message" => "Merge conflict"}}])
      }

      assert {:error, {:http, 409, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "NON-checking 405 (e.g. not enough approvals) → fail-loud, no retry" do
      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} =>
          seq_handler([{405, %{"message" => "Does not have enough approvals"}}])
      }

      assert {:error, {:http, 405, _}} =
               ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end

    test "opts[:method] forces the style (e.g. fast-forward-only)" do
      handlers =
        Map.merge(post_merge_handlers(), %{
          {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}
        })

      assert :ok =
               ForgeClient.merge_pr(
                 "fleet/proj",
                 9,
                 [{:method, "fast-forward-only"} | merge_opts(handlers)]
               )
    end

    test "merge OK → head branch deleted as a SEPARATE spaced call (feed-ordered), slash encoded" do
      # Proves the two-call shape (GET head.ref then DELETE) replacing `delete_branch_after_merge`:
      # a DELETE handler keyed on the %2F-encoded branch answers 204 — reaching it IS the assertion
      # (FakeForge 500s any unhandled route, which delete_head_branch_spaced only warns about;
      # the probe Agent below turns "the DELETE actually happened" into an explicit assert).
      {:ok, probe} = Agent.start_link(fn -> false end)

      handlers = %{
        {"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}},
        {"GET", "/api/v1/repos/fleet/proj/pulls/9"} =>
          {200, %{"head" => %{"ref" => "lcars/issue-9-eng"}}},
        {"DELETE", "/api/v1/repos/fleet/proj/branches/lcars%2Fissue-9-eng"} =>
          fn ->
            Agent.update(probe, fn _ -> true end)
            {204, %{}}
          end
      }

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
      assert Agent.get(probe, & &1), "DELETE /branches/<head.ref> was never called"
    end

    @tag capture_log: true
    test "delete failure is warning-only: merge stays :ok (the merge is the authority)" do
      # No GET/DELETE handlers → FakeForge 500s the post-merge lookup; the merge result must
      # still be :ok (a surviving dead branch is cosmetic, never a merge error).
      handlers = %{{"POST", "/api/v1/repos/fleet/proj/pulls/9/merge"} => {200, %{}}}

      assert :ok = ForgeClient.merge_pr("fleet/proj", 9, merge_opts(handlers))
    end
  end

  # ============================================================
  # F-030 — pagination of source-of-truth reads. FakeForge routes by path ALONE (the `?page=N`
  # query is ignored in the key) → a stateful FUNCTION handler (Agent) returns the pages in
  # order: page 1 FULL (50 items) → the client loops; page 2 partial (< 50) → last page, stop.
  # The result must include all 51 (page 2 was actually read).
  # ============================================================
  describe "pagination (F-030) — beyond 50 items, the following pages are read" do
    # Returns `pages` (list of item lists) in call order; once exhausted, empty page (200, []) →
    # the client stops cleanly (empty < 50). Same Agent mechanics as `seq_handler`.
    defp paged_handler(pages) do
      {:ok, agent} = Agent.start_link(fn -> pages end)

      fn ->
        items =
          Agent.get_and_update(agent, fn
            [p | rest] -> {p, rest}
            [] -> {[], []}
          end)

        {200, items}
      end
    end

    test "list_open_issues: 50 items page 1 + 1 item page 2 → all 51 accumulated (page 2 read)" do
      page1 = for n <- 1..50, do: %{"number" => n, "labels" => []}
      page2 = [%{"number" => 51, "labels" => []}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1, page2])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 51

      # the 51st (present ONLY on page 2) proves the 2nd page was read and accumulated.
      assert Enum.any?(issues, &(&1["number"] == 51))
    end

    # DR-016/BND-057 — THE poller's discovery (org-membership = admission). With `?limit=50` ALONE
    # → beyond 50 repos, projects 51+ were INVISIBLE (no dispatch, no reconciliation, no event nor
    # error — the forge+poll backstop broken in a never-re-read zone). Paginated → seen.
    test "list_org_repos: 50 repos page 1 + 1 repo page 2 → all 51 full_names (repo 51 seen)" do
      page1 = for n <- 1..50, do: %{"full_name" => "fleet/repo-#{n}"}
      page2 = [%{"full_name" => "fleet/repo-51"}]

      handlers = %{
        {"GET", "/api/v1/orgs/fleet/repos"} => paged_handler([page1, page2])
      }

      assert {:ok, names} = ForgeClient.list_org_repos("fleet", opts(handlers))
      assert length(names) == 51
      # the 51st ONLY exists on page 2: its presence proves repo 51 is no longer invisible.
      assert "fleet/repo-51" in names
    end

    # #5.2 D1 — list_open_pulls pagination: the LISTING paginates via /issues
    # (`list_scoped_issues`, SAME code as list_open_issues → already covered by the issues test
    # above). The get_pull fan-out is tested in the `list_open_pulls` describe. No duplicated test
    # here (one listing code = one pagination test).

    test "count_signed_step_runs: a signed step_run on page 2 is counted (source of truth of the anti-runaway budget)" do
      # page 1 full (50 UNSIGNED comments) + page 2 (1 comment carrying a signed step_run marker).
      page1 = for _ <- 1..50, do: %{"user" => %{"login" => "lcars-bot"}, "body" => "blabla"}
      page2 = [%{"user" => %{"login" => "lcars-bot"}, "body" => "done [step_run:engineer:aaa]"}]

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues/42/comments"} => paged_handler([page1, page2])
      }

      # without pagination, the page-2 step_run would be lost → 0; paginated → 1.
      assert {:ok, 1} =
               ForgeClient.count_signed_step_runs(
                 "fleet/lcars",
                 42,
                 Keyword.put(opts(handlers), :forge_bot_login, "lcars-bot")
               )
    end

    test "≤ 50 items: a single page (partial page 1) → identical behavior, no page 2" do
      # 3 items < 50 → the client stops after page 1 (no 2nd call). If a 2nd call went out,
      # paged_handler would return [] → length would stay 3, but above all we prove the ≤50
      # short-circuit.
      page1 = for n <- 1..3, do: %{"number" => n, "labels" => []}

      handlers = %{
        {"GET", "/api/v1/repos/fleet/lcars/issues"} => paged_handler([page1])
      }

      assert {:ok, issues} = ForgeClient.list_open_issues("fleet/lcars", opts(handlers))
      assert length(issues) == 3
    end
  end

  describe "pr_rerequested_reviewers/3 (timeline — human gesture \"request a re-judgment\")" do
    # Gitea timeline events: review (user=judge) / review_request (assignee=judge, removed_assignee=bool).
    defp rev(login, at),
      do: %{"type" => "review", "user" => %{"login" => login}, "created_at" => at}

    defp req(login, at, removed?),
      do: %{
        "type" => "review_request",
        "user" => %{"login" => "admin"},
        "assignee" => %{"login" => login},
        "removed_assignee" => removed?,
        "created_at" => at
      }

    defp timeline(repo, n, events),
      do: %{{"GET", "/api/v1/repos/#{repo}/issues/#{n}/timeline"} => {200, events}}

    # COUNTING (immune to second-level granularity), no temporal ordering: the `at` values below
    # are IDENTICAL (same second) on purpose — the counting must decide the same (that was the
    # hole of the strict `>` found on the forge). PROD sequence: initial request (`req add`) →
    # review → possible re-request.

    test "prod sequence: initial request + review + RE-request (net 2−1>0) → returned, SAME second" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z"),
          req("qualifier", "2026-07-07T14:14:20Z", false)
        ])

      assert {:ok, ["qualifier"]} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "re-request THEN cancellation (removed_assignee, net 2−1−1=0) → [] (cancellation absorbed)" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z"),
          req("qualifier", "2026-07-07T14:14:36Z", false),
          req("qualifier", "2026-07-07T14:17:06Z", true)
        ])

      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "initial request + review, no re-request (net 1−1=0) → [] (nominal, no stray relaunch)" do
      h =
        timeline("fleet/proj", 7, [
          req("qualifier", "2026-07-07T14:14:20Z", false),
          rev("qualifier", "2026-07-07T14:14:20Z")
        ])

      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "1st request never reviewed (0 reviews) → [] (the standard jury covers, not a RE-judgment)" do
      h = timeline("fleet/proj", 7, [req("reviewer", "2026-07-07T14:14:36Z", false)])
      assert {:ok, []} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end

    test "mixed-case login normalized (downcase, jury-consistent)" do
      h =
        timeline("fleet/proj", 7, [
          req("Qualifier", "2026-07-07T14:14:20Z", false),
          rev("Qualifier", "2026-07-07T14:14:20Z"),
          req("Qualifier", "2026-07-07T14:14:20Z", false)
        ])

      assert {:ok, ["qualifier"]} = ForgeClient.pr_rerequested_reviewers("fleet/proj", 7, opts(h))
    end
  end

  describe "assigned_by_qs/1 (#5.2 D1b — forge-side scoping, verified live Gitea 1.26.1)" do
    test "opt absent → empty suffix (no filter)" do
      assert ForgeClient.assigned_by_qs([]) == ""
    end

    test "assigned_by present → &assigned_by=<login>" do
      assert ForgeClient.assigned_by_qs(assigned_by: "lordzurp") == "&assigned_by=lordzurp"
    end

    test "empty login → empty suffix (a degenerate &assigned_by= would return EVERYTHING — scoping anti-regression)" do
      assert ForgeClient.assigned_by_qs(assigned_by: "") == ""
    end
  end

  # ============================================================
  # Confinement E (WI-E4) — a hostile repo/path/ref segment produces a SAFE URL.
  # The right treatment = ENCODING (not slugging: repo=`owner/name`, path=`dir/file` carry
  # legitimate `/`): each COMPONENT is encoded, STRUCTURAL `/` preserved; an injected
  # `..`/`/`/space/`?`/`#` is inert.
  # ============================================================

  describe "real constructed URL — a hostile segment neither traverses nor injects" do
    # Recording Plug: captures the EXACT URL seen server-side (request_path + query_string)
    # AFTER client encoding. This is the proof on real URL construction, not just the helpers.
    defmodule RecordingForge do
      @behaviour Plug
      @impl Plug
      def init(agent), do: agent
      @impl Plug
      def call(conn, agent) do
        Agent.update(agent, fn _ -> %{path: conn.request_path, query: conn.query_string} end)

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          200,
          JSON.encode!(%{"content" => "", "sha" => "x", "state" => "open"})
        )
      end
    end

    defp rec_opts(agent) do
      [base_url: "http://fake.test", token: "t", req_options: [plug: {RecordingForge, agent}]]
    end

    test "hostile repo (fleet/../admin) → no raw `..` component in the request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      # Without encoding: `/api/v1/repos/fleet/../admin/issues/1` → the server NORMALIZES it to
      # `/api/v1/repos/admin/issues/1` (traversal to another repo). Encoding renders it inert.
      ForgeClient.get_issue("fleet/../admin", 1, rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}, "the request_path must contain no raw `..` component"
      assert path =~ "%2E%2E"
    end

    test "hostile ref in query (?ref=main&admin=1) → encoded, no 2nd-param injection" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      # Without encoding: `?ref=main&admin=1` would inject a 2nd `admin` parameter. www-form
      # encodes the `&`.
      ForgeClient.Files.get_file(
        "fleet/lcars",
        "README.md",
        Keyword.put(rec_opts(agent), :ref, "main&admin=1")
      )

      %{query: query} = Agent.get(agent, & &1)

      assert query =~ "ref=main%26admin%3D1"
      refute query =~ "&admin=1", "the ref's `&` must not start a new parameter"
    end

    test "hostile path (../) in get_file → no raw `..` component in the request_path" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      ForgeClient.Files.get_file("fleet/lcars", "../../etc/passwd", rec_opts(agent))
      %{path: path} = Agent.get(agent, & &1)

      refute path =~ ~r{/\.\.(/|$)}
    end
  end
end
