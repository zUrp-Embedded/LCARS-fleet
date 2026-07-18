defmodule Fleet.Pilot.PodIdTest do
  @moduledoc """
  PodId helper (#25): repo-scoped (anti-collision), path-safe (F076), deterministic (BL-055 reuse).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.PodId

  test "for_issue / for_pr: repo-scoped, format <slug>-issue|pr-N-role" do
    assert PodId.for_issue("fleet/poc-8", 1, "engineer") == "fleet-poc-8-issue-1-engineer"
    assert PodId.for_pr("fleet/poc-8", 6, "qualifier") == "fleet-poc-8-pr-6-qualifier"
  end

  test "for_repo: PROJECT pod_id keyed by repo alone, format <slug>-role (slot_scope: project)" do
    assert PodId.for_repo("fleet/poc-8", "engineer") == "fleet-poc-8-engineer"

    # SAME id whatever the issue → 1 identity per (repo, role) → 1 stable Desktop slot.
    assert PodId.for_repo("fleet/poc-8", "engineer") == PodId.for_repo("fleet/poc-8", "engineer")

    # Distinct from instance ids (never `-issue-`/`-pr-`) → no fan-out, no collision.
    refute PodId.for_repo("fleet/poc-8", "engineer") =~ "-issue-"

    refute PodId.for_repo("fleet/poc-8", "engineer") ==
             PodId.for_issue("fleet/poc-8", 1, "engineer")

    # Repo-scoped: two repos → distinct identities.
    refute PodId.for_repo("fleet/repo-a", "engineer") ==
             PodId.for_repo("fleet/repo-b", "engineer")
  end

  test "path-safe slug (F076): `/` → `-`, char outside charset → `-`, result in [A-Za-z0-9._-]" do
    id = PodId.for_issue("owner/repo.name", 2, "reviewer")
    assert id == "owner-repo.name-issue-2-reviewer"
    refute id =~ "/"
    assert id =~ ~r/\A[A-Za-z0-9._-]+\z/
    assert Fleet.Spawner.valid_pod_id?(id)

    # an exotic char (space) is neutralized into `-` (never in a path/tmux name)
    assert PodId.for_issue("a/b c", 1, "x") == "a-b-c-issue-1-x"
  end

  test "slug also neutralizes `..`, forbidden by the spawner's pod_id contract" do
    id = PodId.for_issue("owner/../repo", 2, "reviewer")

    refute id =~ ".."
    assert Fleet.Spawner.valid_pod_id?(id)
  end

  test "deterministic (BL-055): same (repo, n, role) → same id (re-dispatch lands on the pod)" do
    assert PodId.for_issue("fleet/poc-8", 1, "engineer") ==
             PodId.for_issue("fleet/poc-8", 1, "engineer")
  end

  test "collision REGRESSION: same issue #N on TWO repos → DISTINCT pod_ids" do
    a = PodId.for_issue("fleet/repo-a", 1, "engineer")
    b = PodId.for_issue("fleet/repo-b", 1, "engineer")

    refute a == b
    assert a == "fleet-repo-a-issue-1-engineer"
    assert b == "fleet-repo-b-issue-1-engineer"
  end

  test "parse_ref: round-trip with for_issue/for_pr (the format's constructor recognizes it)" do
    # for_issue/for_pr BUILD the format, parse_ref RECOGNIZES it: same module, single source.
    # This round-trip is the guard: if one changes without the other, THIS test breaks (instead of a
    # silent divergence on the poller side that would return [] and loop on reclaim).
    issue_id = PodId.for_issue("fleet/poc-8", 42, "engineer")
    pr_id = PodId.for_pr("fleet/poc-8", 7, "qualifier")

    assert PodId.parse_ref(issue_id, "fleet/poc-8") == {:ok, {:issue, 42}}
    assert PodId.parse_ref(pr_id, "fleet/poc-8") == {:ok, {:pr, 7}}
  end

  test "parse_ref: :error out-of-scope (other repo), on PROJECT pod_id, and on abnormal input" do
    issue_id = PodId.for_issue("fleet/repo-a", 1, "engineer")
    # scope of ANOTHER repo -> not our lock
    assert PodId.parse_ref(issue_id, "fleet/repo-b") == :error

    # project pod_id `<repo>-<role>`: no instance marker -> not a lock ref
    project_id = PodId.for_repo("fleet/poc-8", "engineer")
    assert PodId.parse_ref(project_id, "fleet/poc-8") == :error

    # non-binary input -> :error (no crash)
    assert PodId.parse_ref(nil, "fleet/poc-8") == :error
  end
end
