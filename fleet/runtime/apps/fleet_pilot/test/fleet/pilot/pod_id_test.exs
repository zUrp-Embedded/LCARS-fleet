defmodule Fleet.Pilot.PodIdTest do
  @moduledoc """
  Helper PodId (#25) : repo-scope (anti-collision), path-safe (F076), déterministe (BL-055 reuse).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.PodId

  test "for_issue / for_pr : repo-scopé, format <slug>-issue|pr-N-role" do
    assert PodId.for_issue("fleet/poc-8", 1, "engineer") == "fleet-poc-8-issue-1-engineer"
    assert PodId.for_pr("fleet/poc-8", 6, "qualifier") == "fleet-poc-8-pr-6-qualifier"
  end

  test "slug path-safe (F076) : `/` → `-`, char hors-charset → `-`, résultat dans [A-Za-z0-9._-]" do
    id = PodId.for_issue("owner/repo.name", 2, "reviewer")
    assert id == "owner-repo.name-issue-2-reviewer"
    refute id =~ "/"
    assert id =~ ~r/\A[A-Za-z0-9._-]+\z/

    # un char exotique (espace) est neutralisé en `-` (jamais dans un path/nom tmux)
    assert PodId.for_issue("a/b c", 1, "x") == "a-b-c-issue-1-x"
  end

  test "déterministe (BL-055) : mêmes (repo, n, role) → même id (le re-dispatch retombe sur le pod)" do
    assert PodId.for_issue("fleet/poc-8", 1, "engineer") ==
             PodId.for_issue("fleet/poc-8", 1, "engineer")
  end

  test "RÉGRESSION collision : issue #N identique sur DEUX repos → pod_ids DISTINCTS" do
    a = PodId.for_issue("fleet/repo-a", 1, "engineer")
    b = PodId.for_issue("fleet/repo-b", 1, "engineer")

    refute a == b
    assert a == "fleet-repo-a-issue-1-engineer"
    assert b == "fleet-repo-b-issue-1-engineer"
  end
end
