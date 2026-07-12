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

  test "for_repo : pod_id PROJET keyé repo seul, format <slug>-role (slot_scope: project)" do
    assert PodId.for_repo("fleet/poc-8", "engineer") == "fleet-poc-8-engineer"

    # MÊME id quel que soit le issue → 1 identité par (repo, rôle) → 1 slot Desktop stable.
    assert PodId.for_repo("fleet/poc-8", "engineer") == PodId.for_repo("fleet/poc-8", "engineer")

    # Distinct des ids d'instance (jamais `-issue-`/`-pr-`) → pas de fan-out, pas de collision.
    refute PodId.for_repo("fleet/poc-8", "engineer") =~ "-issue-"

    refute PodId.for_repo("fleet/poc-8", "engineer") ==
             PodId.for_issue("fleet/poc-8", 1, "engineer")

    # Repo-scopé : deux repos → identités distinctes.
    refute PodId.for_repo("fleet/repo-a", "engineer") ==
             PodId.for_repo("fleet/repo-b", "engineer")
  end

  test "slug path-safe (F076) : `/` → `-`, char hors-charset → `-`, résultat dans [A-Za-z0-9._-]" do
    id = PodId.for_issue("owner/repo.name", 2, "reviewer")
    assert id == "owner-repo.name-issue-2-reviewer"
    refute id =~ "/"
    assert id =~ ~r/\A[A-Za-z0-9._-]+\z/
    assert Fleet.Spawner.valid_pod_id?(id)

    # un char exotique (espace) est neutralisé en `-` (jamais dans un path/nom tmux)
    assert PodId.for_issue("a/b c", 1, "x") == "a-b-c-issue-1-x"
  end

  test "slug neutralise aussi `..`, interdit par le contrat pod_id du spawner" do
    id = PodId.for_issue("owner/../repo", 2, "reviewer")

    refute id =~ ".."
    assert Fleet.Spawner.valid_pod_id?(id)
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

  test "parse_ref : round-trip avec for_issue/for_pr (le constructeur du format le reconnait)" do
    # for_issue/for_pr CONSTRUISENT le format, parse_ref le RECONNAIT : meme module, une seule source.
    # Ce round-trip est la garde : si l'un change sans l'autre, CE test casse (au lieu d'une divergence
    # silencieuse cote poller qui rendrait [] et boucle de reclaim).
    issue_id = PodId.for_issue("fleet/poc-8", 42, "engineer")
    pr_id = PodId.for_pr("fleet/poc-8", 7, "qualifier")

    assert PodId.parse_ref(issue_id, "fleet/poc-8") == {:ok, {:issue, 42}}
    assert PodId.parse_ref(pr_id, "fleet/poc-8") == {:ok, {:pr, 7}}
  end

  test "parse_ref : :error hors-scope (autre repo), sur pod_id PROJET, et sur entree anormale" do
    issue_id = PodId.for_issue("fleet/repo-a", 1, "engineer")
    # scope d'un AUTRE repo -> pas notre verrou
    assert PodId.parse_ref(issue_id, "fleet/repo-b") == :error

    # pod_id projet `<repo>-<role>` : aucun marqueur d'instance -> pas de ref de verrou
    project_id = PodId.for_repo("fleet/poc-8", "engineer")
    assert PodId.parse_ref(project_id, "fleet/poc-8") == :error

    # entree non-binaire -> :error (pas de crash)
    assert PodId.parse_ref(nil, "fleet/poc-8") == :error
  end
end
