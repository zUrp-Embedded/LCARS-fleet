defmodule Fleet.Pilot.ForgeProtocol do
  @moduledoc """
  **Pure** vocabulary of the forge-state-machine wire-protocol: the forge IS the state machine,
  these formats are its thread. SINGLE SOURCE of the markers recorded on issues/PRs and of the
  feature-branches. No I/O — only build + parse of strings (the HTTP ops that
  *post*/*read* them live in `Fleet.Pilot.ForgeClient`).

  Counterpart of `Fleet.Labels` (both carry the wire-protocol): `Labels` = the
  **lock-labels** (`lcars-in-flight`/`lcars-awaits-arch`); here = **branches,
  route/step_run/onboard markers, result blocks** and the **trust primitive** `system_authored?/2`.

  **Co-located build+parse invariant**: each format has its BUILDER and its PARSER in
  THIS module, glued to each other — a format change happens HERE, both together,
  never one without the other (no drift between what is written and what is re-read).
  The consumers (`StepDispatcher`, `StepRunConsumer`, `StepRunCompleter`, `Poller`) call these
  functions DIRECTLY. Only `parse_feature_branch/1` is also re-exported by `ForgeClient`
  (`defdelegate`): `fleet_mcp` reaches it via the `:forge_client` seam to avoid a compile-time
  dependency on fleet_pilot.

  **Last revised**: 2026-08-02
  """

  # ============================================================
  # System feature-branch `lcars/issue-<n>-<role>`.
  # ============================================================

  # SINGLE-SOURCE literal of the format: builder AND parser derive from it (zero token written twice).
  @feature_branch_prefix "lcars/issue-"
  # Regex DERIVED from the same literal — `Regex.escape` neutralises the `/` (and any meta-character) of the prefix
  # → inert literal in the pattern, never interpreted as regex syntax.
  @feature_branch_rx Regex.compile!("^" <> Regex.escape(@feature_branch_prefix) <> "(\\d+)-(.+)$")

  @doc """
  Builds the system feature-branch `lcars/issue-<n>-<role>` — the single BUILDER of the format,
  derived from `@feature_branch_prefix` just like its parser `parse_feature_branch/1`: a format
  change happens on THIS single literal, build and parse follow (no more token twice).
  Guaranteed identity: `parse_feature_branch(feature_branch(n, role)) == {:ok, {n, role}}`.
  """
  @spec feature_branch(integer(), String.t()) :: String.t()
  # => "lcars/issue-<n>-<role>"
  def feature_branch(n, role) when is_integer(n) and is_binary(role),
    do: "#{@feature_branch_prefix}#{n}-#{role}"

  @doc """
  Extracts `{issue_number, role}` from a system feature-branch `lcars/issue-<n>-<role>` (format
  built by `feature_branch/2`, its co-located inverse). Serves the PR-driven judge dispatch to go
  back from the PR (head.ref) to the issue. `:error` if the ref is not a fleet feature-branch (external
  PR / manual branch -> ignored by the dispatch, never misrouted).
  """
  @spec parse_feature_branch(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_feature_branch(head) when is_binary(head) do
    case Regex.run(@feature_branch_rx, head) do
      [_, n, role] -> {:ok, {String.to_integer(n), role}}
      _ -> :error
    end
  end

  def parse_feature_branch(_), do: :error

  @doc """
  Selects the Fleet PRs from a list of raw forge pull maps: every pull whose `head.ref` parses as a
  feature-branch (`lcars/issue-N-<role>`) yields `{issue_number, pull}` — the SINGLE loop behind the
  in-Pilot issue↔PR correlations (C-05). Callers keep their LOCAL
  projection: `Poller` → the set of issue numbers; `StepRunBuild` → the head.ref of issue N's PR. The
  MCP `Delegation` correlation is NOT wired here (a `fleet_mcp` compile dep on Pilot is forbidden, and
  extending the forge seam with the selector would force every forge stub to implement it) — it keeps a
  local loop over the SAME single-authority parse (`forge.parse_feature_branch` seam → this module).
  """
  @spec fleet_prs_by_issue([map()]) :: [{integer(), map()}]
  def fleet_prs_by_issue(pulls) when is_list(pulls) do
    Enum.flat_map(pulls, fn pr ->
      case parse_feature_branch(get_in(pr, ["head", "ref"]) || "") do
        {:ok, {n, _role}} -> [{n, pr}]
        :error -> []
      end
    end)
  end

  # (The workflow_map position is NOT a `[lcars-route:...]` comment-marker: it lives in the
  # issue's SCOPED label `stage/*` — Gitea native mutex, human-visible, read without a comment scan.
  # Builder/reader: `Fleet.Pilot.ForgeClient.post_route`/`get_route`.)

  # ============================================================
  # Signed STEP_RUN marker `[step_run:<role>:<sha>]` — forge-native anti-runaway counter.
  # ============================================================

  # SINGLE-SOURCE literal: builder AND predicate derive from it.
  @step_run_prefix "[step_run:"
  # Regex DERIVED from the same literal — `Regex.escape` neutralises the `[` of the prefix. NO anchor: the
  # marker is placed at the end of a comment body.
  @step_run_marker_rx Regex.compile!(Regex.escape(@step_run_prefix) <> "[^:\\]]+:[^:\\]]+\\]")

  @doc """
  Format of the signed step_run marker `[step_run:<role>:<sha>]` (builder derived from `@step_run_prefix`, just like
  its predicate `step_run_marker?/1` — a format change happens on THIS single literal). Posted by
  `StepRunCompleter` at step-run end, also serves as `:dedup_signature` (idempotent replay).

  Round-trip builder -> predicate (the predicate recognises what the builder records):

      iex> marker = Fleet.Pilot.ForgeProtocol.step_run_marker("engineer", "deadbeef")
      iex> marker
      "[step_run:engineer:deadbeef]"
      iex> Fleet.Pilot.ForgeProtocol.step_run_marker?(marker)
      true
      iex> Fleet.Pilot.ForgeProtocol.step_run_marker?("juste un commentaire")
      false
  """
  @spec step_run_marker(String.t(), String.t()) :: String.t()
  def step_run_marker(role, sha) when is_binary(role) and is_binary(sha) do
    # => "[step_run:<role>:<sha>]"
    "#{@step_run_prefix}#{role}:#{sha}]"
  end

  # ============================================================
  # PUBLISH-FAIL marker `[publish-fail:issue-<n>:base-<sha12>]` — forge-native consecutive-failure
  # counter (chantier frein-publish). The gate BASE moves ONLY on a successful push, so "consecutive
  # failures" ≡ "failures sharing a base": no success marker, no RAM state — the max same-base group
  # among an issue's markers IS the streak, and a delivered brick starts a fresh group by construction.
  # ============================================================

  @publish_fail_prefix "[publish-fail:issue-"
  # {4,12}: the parser accepts what the builder can PRODUCE — the builder slices to ≤12, and a
  # test base can legitimately be shorter than 12 (git's shortest abbreviation is 4). A parser
  # stricter than its builder silently uncounts markers the poster just recorded.
  @publish_fail_rx Regex.compile!(
                     Regex.escape(@publish_fail_prefix) <> "(\\d+):base-([0-9a-f]{4,12})\\]"
                   )

  @doc """
  Marker of ONE publish failure for issue `n` on gate base `base_sha` (truncated 12 hex) —
  builder and parser derive from the same literal. Posted by `StepRunCompleter` when the
  deliverable publication fails; counted by `Remediation.dispatch_rework` (the brake).

      iex> m = Fleet.Pilot.ForgeProtocol.publish_fail_marker(7, String.duplicate("a", 40))
      iex> m
      "[publish-fail:issue-7:base-aaaaaaaaaaaa]"
      iex> Fleet.Pilot.ForgeProtocol.parse_publish_fail_marker(m)
      {:ok, {7, "aaaaaaaaaaaa"}}
      iex> Fleet.Pilot.ForgeProtocol.parse_publish_fail_marker("un commentaire")
      :error
      iex> Fleet.Pilot.ForgeProtocol.parse_publish_fail_marker(
      ...>   Fleet.Pilot.ForgeProtocol.publish_fail_marker(42, "cafe")
      ...> )
      {:ok, {42, "cafe"}}
  """
  @spec publish_fail_marker(integer(), String.t()) :: String.t()
  def publish_fail_marker(n, base_sha) when is_integer(n) and is_binary(base_sha) do
    "#{@publish_fail_prefix}#{n}:base-#{String.slice(base_sha, 0, 12)}]"
  end

  @doc "Extracts `{issue_n, base12}` from a body carrying a publish-fail marker; `:error` otherwise."
  @spec parse_publish_fail_marker(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_publish_fail_marker(body) when is_binary(body) do
    case Regex.run(@publish_fail_rx, body) do
      [_, n, base12] -> {:ok, {String.to_integer(n), base12}}
      _ -> :error
    end
  end

  def parse_publish_fail_marker(_), do: :error

  @doc false
  # Pure: does a body carry a signed step_run marker? Inverse of `step_run_marker/2` for the forge-native
  # counting (`ForgeClient.count_signed_step_runs`).
  def step_run_marker?(body) when is_binary(body), do: Regex.match?(@step_run_marker_rx, body)
  def step_run_marker?(_), do: false

  @parked_prefix "[lcars-parked]"

  @doc """
  Title of the PARKED marker issue (BL-6-30) — an OPEN issue whose title carries the
  `[lcars-parked]` prefix IS the project's closed state ("the forge IS the state machine";
  same protocol-object class as the in-flight lock label). Built by `close_project`,
  recognized by `parked_issue_title?/1` on the PREFIX alone (suffix and body free — the body
  documents the reopening paths to the human), closed by `open_project` (ALL of them:
  concurrent closes can legitimately leave two, the state holds while at least one is open).
  Trust model: same as the `stage/*` labels — a human mutating the marker mutates the state,
  deliberately (UI-close = legitimate unpark).
  """
  @spec parked_issue_title() :: String.t()
  def parked_issue_title, do: "#{@parked_prefix} projet fermé — la fleet ne dispatche plus ici"

  @doc "Does this issue TITLE carry the parked prefix? (the state test, prefix-only)"
  @spec parked_issue_title?(term()) :: boolean()
  def parked_issue_title?(title) when is_binary(title),
    do: String.starts_with?(title, @parked_prefix)

  def parked_issue_title?(_), do: false

  @merge_marker_rx ~r/\[merge:pr-(\d+)\]/

  @doc """
  Format of the merge marker `[merge:pr-<n>]` — posted ON THE ISSUE by the gatekeeper seal at
  merge (also its `:dedup_signature`). This marker IS the durable issue→PR correlation: Gitea
  (1.26.4, verified live 2026-07-19) REWRITES a merged PR's `head.ref` to `refs/pull/N/head`
  once the head branch is deleted, so no branch scan can resolve a delivered brick's PR — the
  protocol carries the link instead. Trust model: same as the `stage/*` labels (a forged marker
  = compromised role account = nuke&redeploy, not this rail's concern).

  Round-trip builder -> parser:

      iex> marker = Fleet.Pilot.ForgeProtocol.merge_marker(6)
      iex> marker
      "[merge:pr-6]"
      iex> Fleet.Pilot.ForgeProtocol.parse_merge_marker("scellé.\\n\\n" <> marker)
      {:ok, 6}
      iex> Fleet.Pilot.ForgeProtocol.parse_merge_marker("juste un commentaire")
      :error
  """
  @spec merge_marker(integer()) :: String.t()
  def merge_marker(pr_number) when is_integer(pr_number), do: "[merge:pr-#{pr_number}]"

  @spec parse_merge_marker(term()) :: {:ok, integer()} | :error
  def parse_merge_marker(body) when is_binary(body) do
    case Regex.run(@merge_marker_rx, body) do
      [_, n] -> {:ok, String.to_integer(n)}
      _ -> :error
    end
  end

  def parse_merge_marker(_), do: :error

  # ============================================================
  # ` ```result ` block — serialises a step's `outputs` in the step_run comment.
  # ============================================================

  @result_block_rx ~r/```result\n(.*?)\n```/s
  @result_fence_limit 8192

  @doc """
  Format of the ` ```result ` block (serialises a step's `outputs` in the step_run comment).
  Co-located with its parser `parse_result_block/1` — round-trip guaranteed. `nil`/empty →
  `""` (no noise). JSON fenced if ≤ 8 KB; beyond that, a note pointing to the branch's
  deliverable (never truncated JSON = invalid). `\\n\\n` prefix included (body separator).
  """
  @spec result_block(map() | nil) :: String.t()
  def result_block(outputs) when is_map(outputs) and map_size(outputs) > 0 do
    json = Jason.encode!(outputs)

    if byte_size(json) <= @result_fence_limit do
      "\n\n```result\n#{json}\n```"
    else
      "\n\n_(result #{byte_size(json)} o — trop volumineux pour le comment ; livrable complet sur la branche système)_"
    end
  end

  def result_block(_), do: ""

  @doc false
  # Pure: extracts the map from the FIRST ```result block of a body (`Regex.run` = first match),
  # otherwise nil. The "last wins" semantics lives at the CALLER: `ForgeClient.get_predecessor_result`
  # reverses the comment list before `find_value`, so the most recent comment's block wins.
  def parse_result_block(body) when is_binary(body) do
    case Regex.run(@result_block_rx, body) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_result_block(_), do: nil

  # ============================================================
  # Trust primitive (bot-authored markers on comments: route/step_run/result).
  # (WS3: admission is org-membership — no server-side admission marker in this vocabulary.)
  # ============================================================

  @doc false
  # Pure: a forge OBJECT (comment OR issue — same Gitea wire shape `{"user": {"login": …}}`) is
  # TRUSTED iff its author = the fleet's system (bot) account. A forge user
  # (human/attacker) has a different login → its markers are ignored. The SINGLE predicate of the
  # trust primitive: the marker readers on comments (`ForgeClient` route/step_run/result)
  # all go through here — no copy.
  def system_authored?(object, bot_login)
      when is_map(object) and is_binary(bot_login) and bot_login != "" do
    get_in(object, ["user", "login"]) == bot_login
  end

  def system_authored?(_object, _bot), do: false
end
