defmodule Fleet.Spawner.Pod.CompletedPayloadTest do
  # async: true — `build/2` est PUR (aucune I/O, aucune mutation, aucun state/config global) : que du
  # calcul déterministe sur les champs LUS du `data`. Rien à sérialiser entre tests.
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.CompletedPayload

  # cap_profile minimal : `build/2` ne lit QUE le rôle (`Fleet.CapProfile.name` → metadata["name"]) et
  # le projet statique (`spec["project"]`, résolu via `LaunchSpec.effective_project`). On le laisse vide
  # par défaut → le projet EFFECTIF vient des `opts[:project]` du data (dynamique), ce que pose le
  # dispatcher en prod.
  defp cap_profile(spec) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: spec
    }
  end

  # data représentatif du gen_statem au moment de l'extract (les SEULS champs lus par `build/2`).
  defp data(opts \\ [], spec \\ %{}) do
    %{
      pod_id: "pod-abc",
      issue_id: "issue-42",
      opts: opts,
      cap_profile: cap_profile(spec),
      pod_dir: "/home/human/pods/pod_pod-abc"
    }
  end

  describe "build/2 — payload nu (pas de projet)" do
    test "sans projet → base uniquement (pod_id/issue_id/result), aucune clé de step-run" do
      payload = CompletedPayload.build(data(), %{"summary" => "done"})

      assert payload == %{
               "pod_id" => "pod-abc",
               "issue_id" => "issue-42",
               "result" => %{"summary" => "done"}
             }

      # Aucun contexte de fin-de-step-run sur un pod sans projet (memory-X, architect).
      refute Map.has_key?(payload, "workspace")
      refute Map.has_key?(payload, "role")
      refute Map.has_key?(payload, "repository")
    end

    test "projet SANS repo_path (map vide implicite) → payload nu" do
      # `effective_project` rend `%{}` (ni opts[:project], ni spec["project"]) → clause `_` → base.
      payload = CompletedPayload.build(data([], %{"project" => %{}}), %{})
      assert payload == %{"pod_id" => "pod-abc", "issue_id" => "issue-42", "result" => %{}}
    end
  end

  describe "build/2 — pod-projet (repo_path présent)" do
    test "projet avec repo_path → workspace + base_sha + gate_base_sha + role, sans repo/workflow_map" do
      proj = %{"repo_path" => "https://forge/x.git", "base_sha" => "sha-base"}
      payload = CompletedPayload.build(data(project: proj), %{"summary" => "ok"})

      assert payload["pod_id"] == "pod-abc"
      assert payload["issue_id"] == "issue-42"
      assert payload["result"] == %{"summary" => "ok"}
      # Autorité unique du sous-dossier workspace = <pod_dir>/workspace.
      assert payload["workspace"] == "/home/human/pods/pod_pod-abc/workspace"
      assert payload["base_sha"] == "sha-base"
      # Rôle gravé au spawn (source unique Fleet.CapProfile.name).
      assert payload["role"] == "engineer"

      # Projet sans `"repo"` → pas d'enrichissement multi-projet ; sans opts workflow_map → pas de ctx.
      refute Map.has_key?(payload, "repository")
      refute Map.has_key?(payload, "remote")
      refute Map.has_key?(payload, "workflow_map")
    end

    test "gate_base_sha explicite prime ; absent → fallback base_sha" do
      with_gate =
        CompletedPayload.build(
          data(project: %{"repo_path" => "r", "base_sha" => "b", "gate_base_sha" => "g"}),
          %{}
        )

      assert with_gate["gate_base_sha"] == "g"

      # gate_base_sha absent → égalisé à base_sha (forward build/rework).
      fallback =
        CompletedPayload.build(data(project: %{"repo_path" => "r", "base_sha" => "b"}), %{})

      assert fallback["gate_base_sha"] == "b"
    end

    test "projet avec repo → repository{full_name} + remote (repo_path)" do
      proj = %{
        "repo_path" => "https://forge/owner/name.git",
        "base_sha" => "sha-base",
        "repo" => "owner/name"
      }

      payload = CompletedPayload.build(data(project: proj), %{})

      assert payload["repository"] == %{"full_name" => "owner/name"}
      # `remote` = l'URL de push = repo_path.
      assert payload["remote"] == "https://forge/owner/name.git"
    end

    test "projet EFFECTIF : opts[:project] prime sur spec[project]" do
      # brief dynamique (opts) > statique (spec) — source unique LaunchSpec.effective_project.
      dynamic = %{"repo_path" => "dyn", "base_sha" => "dyn-sha"}
      static = %{"repo_path" => "stat", "base_sha" => "stat-sha"}
      payload = CompletedPayload.build(data([project: dynamic], %{"project" => static}), %{})
      assert payload["base_sha"] == "dyn-sha"
    end

    test "contexte workflow_map (opts :workflow_map + :step binaires) → clés workflow_map/step" do
      proj = %{"repo_path" => "r", "base_sha" => "b"}

      payload =
        CompletedPayload.build(data(project: proj, workflow_map: "wm-1", step: "build"), %{})

      assert payload["workflow_map"] == "wm-1"
      assert payload["step"] == "build"
    end
  end

  describe "build/2 — branche workflow_map_id (spawn workflow_map explicite)" do
    test "workflow_map_id + step dans opts → payload workflow_map (court-circuite le lookup projet)" do
      # Cette branche N'appelle PAS effective_project : le contexte workflow_map est direct.
      payload =
        CompletedPayload.build(
          data(workflow_map_id: "wm-77", step: "review", project: %{"repo_path" => "ignored"}),
          %{"r" => 1}
        )

      assert payload == %{
               "pod_id" => "pod-abc",
               "issue_id" => "issue-42",
               "result" => %{"r" => 1},
               "workflow_map_id" => "wm-77",
               "step" => "review"
             }
    end
  end

  describe "build/2 — pureté (ne mute pas le data)" do
    test "le data passé n'est pas modifié" do
      d = data(project: %{"repo_path" => "r", "base_sha" => "b", "repo" => "o/n"})
      _ = CompletedPayload.build(d, %{"x" => 1})

      assert d.pod_id == "pod-abc"
      assert d.issue_id == "issue-42"
      assert d.opts == [project: %{"repo_path" => "r", "base_sha" => "b", "repo" => "o/n"}]
    end
  end
end
