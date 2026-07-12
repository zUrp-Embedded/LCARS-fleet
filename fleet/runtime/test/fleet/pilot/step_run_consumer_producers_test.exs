defmodule Fleet.Pilot.StepRunConsumerProducersTest do
  @moduledoc """
  Q2 DRAFT producers (2026-07-09) — `StepRunConsumer` alimente 2 rails Cat-5 dormants qui avaient un
  consommateur (`Starfleet.DriftMonitor`) mais AUCUN producteur :

  - `workflow_map.failed` — émis sur un échec de LOAD workflow_map (`:workflow_map_load_failed`).
  - `audit.verdict` — émis sur un verdict de juge escalade-digne (branche `other` de `apply_verdict`).

  Les deux sont émis source `:workflow` (invariant anti-spoof DriftMonitor) via `safe_emit` :
  un échec d'émission est loggué warning par le producteur et ne bloque jamais l'escalade porteuse
  (le Bus est le fast-path lossy ; la vérité durable reste le rail forge).
  On subscribe au Bus RÉEL (c'est l'objet du test : prouver l'émission) → `async: false` (état global
  Bus partagé) + noms/issues uniques pour l'hermétisme.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.StepRunConsumer

  # Loader : "bad-q2" raise (introuvable → :workflow_map_load_failed) ; "judgemap-q2" = 1 step JUGE.
  defmodule Loader do
    def load!("judgemap-q2") do
      %{
        "name" => "judgemap-q2",
        "steps" => %{
          "gate" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          }
        }
      }
    end

    def load!(_), do: raise("workflow_map introuvable")
  end

  # Completer : capture complete_pr + await_arch (freeze_to_arch → await_arch).
  defmodule CaptureCompleter do
    def complete_pr(step_run, opts),
      do: send(self(), {:step_run, step_run, opts}) && {:ok, :captured}

    def await_arch(step_run, opts),
      do: send(self(), {:await_arch, step_run, opts}) && {:ok, :awaiting_arch}
  end

  defmodule StubSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok
  end

  defp dmode,
    do: fn
      "engineer" -> "git_native"
      _ -> "payload"
    end

  defp state do
    %StepRunConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      step_run_completer: CaptureCompleter,
      deliverable_mode_fun: dmode(),
      loader: Loader,
      spawner: StubSpawner,
      gate_evals: %{}
    }
  end

  setup do
    Bus.subscribe()
    :ok
  end

  describe "workflow_map.failed draft producer" do
    test "échec de LOAD workflow_map → émet workflow_map.failed (source :workflow), PAS d'audit.verdict" do
      payload = %{
        "issue_id" => "issue-42",
        "workspace" => "/ws",
        "base_sha" => "cafe",
        "role" => "engineer",
        "workflow_map" => "bad-q2",
        "step" => "build",
        "result" => %{}
      }

      assert {:error, {:workflow_map_load_failed, _, _}} =
               StepRunConsumer.maybe_complete(payload, state())

      assert_receive %Fleet.Event{
                       source: :workflow,
                       type: :"workflow_map.failed",
                       payload: %{
                         "workflow_map" => "bad-q2",
                         "issue" => 42,
                         "role" => "engineer",
                         "producer" => "draft:step_run_consumer"
                       }
                     },
                     500

      # Rail ciblé : un échec de load n'est PAS un verdict → pas d'audit.verdict.
      refute_received %Fleet.Event{type: :"audit.verdict"}
    end
  end

  describe "audit.verdict draft producer" do
    test "verdict juge escalade-digne → émet audit.verdict (decision escalate, vrai verdict en details) + freeze arch" do
      payload = %{
        "issue_id" => "issue-42",
        "workspace" => "/ws",
        "base_sha" => "cafe",
        "role" => "consultant",
        "workflow_map" => "judgemap-q2",
        "step" => "gate",
        "result" => %{"decision" => "halt_wait_input", "reason" => "info manquante"}
      }

      StepRunConsumer.maybe_complete(payload, state())

      assert_receive %Fleet.Event{
                       source: :workflow,
                       type: :"audit.verdict",
                       payload: %{"decision_json" => json}
                     },
                     500

      # decision-v1 : decision "escalate" (matche la policy coord escalate.audit_verdict) + reason ;
      # le VRAI verdict juge est préservé dans details (rien perdu par la traduction draft).
      decoded = Jason.decode!(json)
      assert decoded["decision"] == "escalate"
      assert decoded["reason"] == "audit_verdict"
      assert decoded["details"]["verdict"] == "halt_wait_input"
      assert decoded["details"]["issue"] == 42
      assert decoded["details"]["role"] == "consultant"

      # L'escalade humaine (freeze_to_arch) a bien eu lieu APRÈS l'émission (le draft ne remplace rien).
      assert_received {:await_arch, _step_run, _opts}

      # Rail ciblé : un verdict n'est pas un échec de load → pas de workflow_map.failed.
      refute_received %Fleet.Event{type: :"workflow_map.failed"}
    end
  end
end
