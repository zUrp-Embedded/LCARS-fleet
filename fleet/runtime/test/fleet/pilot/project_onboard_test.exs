defmodule Fleet.Pilot.ProjectOnboardTest do
  @moduledoc """
  F-C084 — `onboard/2` CREATES a fresh project: it scaffolds `main` + pushes over it. A PRE-EXISTING
  repo is NOT a safe target (clobbering the `main` of a real repo: a human's repo onboarded by mistake,
  or a complete project re-onboarded). The PURE decision `classify_create_repo/3` fails loud on
  `{:ok, :already_exists}` (create_repo 409); only a genuine CREATE proceeds. `create_repo` sits at the
  HEAD of onboard's `with` (before clone/scaffold/push) → the error short-circuits the sequence by
  construction: nothing is written to the existing repo. (Adopting an existing repo goes through
  `import/2`, which does NOT scaffold `main`.)
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ProjectOnboard

  describe "classify_create_repo/3 (F-C084 — pre-existing repo is not an onboard target)" do
    test "genuine CREATE ({:ok, full_name}) → {:ok, full_name} (onboard owns the fresh repo)" do
      assert {:ok, "fleet/neuf"} =
               ProjectOnboard.classify_create_repo({:ok, "fleet/neuf"}, "fleet", "neuf")
    end

    test "repo ALREADY existing (409 → {:ok, :already_exists}) → {:error, {:repo_already_exists, _}} (FAIL-LOUD)" do
      # Core of the finding: treating already_exists as SUCCESS would make onboard clone + scaffold +
      # push onto the existing `main` = silent CLOBBER. Fail-loud instead → the operator uses
      # import_project (adopts, content intact) or deletes the stale/partial repo.
      assert {:error, {:repo_already_exists, "fleet/deja"}} =
               ProjectOnboard.classify_create_repo({:ok, :already_exists}, "fleet", "deja")
    end

    test "forge error propagated as-is (no interpretation)" do
      assert {:error, {:http, 500, "boom"}} =
               ProjectOnboard.classify_create_repo({:error, {:http, 500, "boom"}}, "fleet", "x")
    end
  end
end
