defmodule Fleet.Spawner.Pod.CompletedPayloadTest do
  # async: true — `build/2` is PURE (no I/O, no mutation, no global state/config): only
  # deterministic computation over the fields READ from `data`. Nothing to serialize between tests.
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.CompletedPayload

  # minimal cap_profile: `build/2` reads ONLY the role (`Fleet.CapProfile.name` → metadata["name"])
  # and the static project (`spec["project"]`, resolved via `LaunchSpec.effective_project`). Left
  # empty by default → the EFFECTIVE project comes from the data's `opts[:project]` (dynamic), which
  # is what the dispatcher sets in prod.
  defp cap_profile(spec) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: spec
    }
  end

  # data representative of the gen_statem at extract time (the ONLY fields read by `build/2`).
  defp data(opts \\ [], spec \\ %{}) do
    %{
      pod_id: "pod-abc",
      issue_id: "issue-42",
      opts: opts,
      cap_profile: cap_profile(spec),
      pod_dir: "/home/human/pods/pod_pod-abc"
    }
  end

  describe "build/2 — bare payload (no project)" do
    test "without project → base only (pod_id/issue_id/result), no step-run key" do
      payload = CompletedPayload.build(data(), %{"summary" => "done"})

      assert payload == %{
               "pod_id" => "pod-abc",
               "issue_id" => "issue-42",
               "result" => %{"summary" => "done"}
             }

      # No end-of-step-run context on a project-less pod (memory-X, architect).
      refute Map.has_key?(payload, "workspace")
      refute Map.has_key?(payload, "role")
      refute Map.has_key?(payload, "repository")
    end

    test "BL-6-20: the stamped brief_kind rides the BASE payload (a payload-only judge routes by it)" do
      payload = CompletedPayload.build(data(brief_kind: "judge"), %{"decision" => "continue"})

      assert payload["brief_kind"] == "judge"
      # Still a bare payload otherwise (no project) — the stamp is base-level by design.
      refute Map.has_key?(payload, "workspace")
    end

    test "BL-6-20: no stamp in the spawn opts → no brief_kind key (legacy pods keep their shape)" do
      payload = CompletedPayload.build(data(), %{})
      refute Map.has_key?(payload, "brief_kind")
    end

    test "project WITHOUT repo_path (implicit empty map) → bare payload" do
      # `effective_project` returns `%{}` (neither opts[:project] nor spec["project"]) → `_` clause → base.
      payload = CompletedPayload.build(data([], %{"project" => %{}}), %{})
      assert payload == %{"pod_id" => "pod-abc", "issue_id" => "issue-42", "result" => %{}}
    end
  end

  describe "build/2 — project pod (repo_path present)" do
    test "project with repo_path → workspace + base_sha + gate_base_sha + role, without repo/workflow_map" do
      proj = %{"repo_path" => "https://forge/x.git", "base_sha" => "sha-base"}
      payload = CompletedPayload.build(data(project: proj), %{"summary" => "ok"})

      assert payload["pod_id"] == "pod-abc"
      assert payload["issue_id"] == "issue-42"
      assert payload["result"] == %{"summary" => "ok"}
      # Single authority for the workspace subdir = <pod_dir>/workspace.
      assert payload["workspace"] == "/home/human/pods/pod_pod-abc/workspace"
      assert payload["base_sha"] == "sha-base"
      # Role engraved at spawn (single source Fleet.CapProfile.name).
      assert payload["role"] == "engineer"

      # Project without `"repo"` → no multi-project enrichment; without workflow_map opts → no ctx.
      refute Map.has_key?(payload, "repository")
      refute Map.has_key?(payload, "remote")
      refute Map.has_key?(payload, "workflow_map")
    end

    test "explicit gate_base_sha wins; absent → base_sha fallback" do
      with_gate =
        CompletedPayload.build(
          data(project: %{"repo_path" => "r", "base_sha" => "b", "gate_base_sha" => "g"}),
          %{}
        )

      assert with_gate["gate_base_sha"] == "g"

      # gate_base_sha absent → equalized to base_sha (forward build/rework).
      fallback =
        CompletedPayload.build(data(project: %{"repo_path" => "r", "base_sha" => "b"}), %{})

      assert fallback["gate_base_sha"] == "b"
    end

    test "project with repo → repository{full_name} + remote (repo_path)" do
      proj = %{
        "repo_path" => "https://forge/owner/name.git",
        "base_sha" => "sha-base",
        "repo" => "owner/name"
      }

      payload = CompletedPayload.build(data(project: proj), %{})

      assert payload["repository"] == %{"full_name" => "owner/name"}
      # `remote` = the push URL = repo_path.
      assert payload["remote"] == "https://forge/owner/name.git"
    end

    test "EFFECTIVE project: opts[:project] wins over spec[project]" do
      # dynamic brief (opts) > static (spec) — single source LaunchSpec.effective_project.
      dynamic = %{"repo_path" => "dyn", "base_sha" => "dyn-sha"}
      static = %{"repo_path" => "stat", "base_sha" => "stat-sha"}
      payload = CompletedPayload.build(data([project: dynamic], %{"project" => static}), %{})
      assert payload["base_sha"] == "dyn-sha"
    end

    test "workflow_map context (binary :workflow_map + :step opts) → workflow_map/step keys" do
      proj = %{"repo_path" => "r", "base_sha" => "b"}

      payload =
        CompletedPayload.build(data(project: proj, workflow_map: "wm-1", step: "build"), %{})

      assert payload["workflow_map"] == "wm-1"
      assert payload["step"] == "build"
    end
  end

  describe "build/2 — purity (does not mutate the data)" do
    test "the passed data is not modified" do
      d = data(project: %{"repo_path" => "r", "base_sha" => "b", "repo" => "o/n"})
      _ = CompletedPayload.build(d, %{"x" => 1})

      assert d.pod_id == "pod-abc"
      assert d.issue_id == "issue-42"
      assert d.opts == [project: %{"repo_path" => "r", "base_sha" => "b", "repo" => "o/n"}]
    end
  end
end
