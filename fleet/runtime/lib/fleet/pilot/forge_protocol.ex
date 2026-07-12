defmodule Fleet.Pilot.ForgeProtocol do
  @moduledoc """
  **Pure** vocabulary of the forge-state-machine wire-protocol: the forge IS the state machine,
  these formats are its thread. SINGLE SOURCE of the markers recorded on issues/PRs and of the
  feature-branches. No I/O — only build + parse of strings (the HTTP ops that
  *post*/*read* them live in `Fleet.Pilot.ForgeClient`).

  Counterpart of `Fleet.Pilot.Labels` (both carry the wire-protocol): `Labels` = the
  **lock-labels** (`lcars-in-flight`/`lcars-awaits-arch`); here = **branches,
  route/step_run/onboard markers, result blocks** and the **trust primitive** `system_authored?/2`.

  **Co-located build+parse invariant**: each format has its BUILDER and its PARSER in
  THIS module, glued to each other — a format change happens HERE, both together,
  never one without the other (no more drift between what is written and what is re-read).
  The consumers (`StepDispatcher`, `StepRunConsumer`, `StepRunCompleter`, `Poller`) call these
  functions DIRECTLY. Only `parse_feature_branch/1` is also re-exported by `ForgeClient`
  (`defdelegate`): `fleet_mcp` reaches it via the `:forge_client` seam to avoid a compile-time
  dependency on fleet_pilot.
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

  # (The workflow_map position is no longer a `[lcars-route:...]` comment-marker: it lives in the
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

  @doc false
  # Pure: does a body carry a signed step_run marker? Inverse of `step_run_marker/2` for the forge-native
  # counting (`ForgeClient.count_signed_step_runs`).
  def step_run_marker?(body) when is_binary(body), do: Regex.match?(@step_run_marker_rx, body)
  def step_run_marker?(_), do: false

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
  # (The admission marker `[lcars-onboarded:<human>]` + `admitted?`/`post_onboard_marker` are
  # REMOVED — WS3: admission is org-membership, no more server-side seal to set/read.)
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
