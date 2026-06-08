defmodule Fleet.Pilot.HopConsumerGateTest do
  @moduledoc """
  A2.3 — la gate du stage FINI décide la fin-de-hop (DN forge-state-machine §9).
  On pilote `HopConsumer.maybe_complete` (avec le VRAI `HopCompleter`) contre un sim
  forge + des cartes gatées, et on prouve les trois issues :

    * gate `:pass`              → avance (next_stage)
    * gate `{:fail}`            → rebond vers le 1er stage, BORNÉ (budget hops)
    * budget épuisé             → `{:error, {:rework_exhausted, _}}` (aucune écriture forge)
    * gate `{:dispatch_gatekeeper}` (soft) → `{:error, {:gate_pending, _}}` (différé A2.3b)
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # ── Sim forge : capture les writes via send(self()), sert un compteur de hops
  #    configurable par `forge_opts[:_hops]` (le bound lit count_signed_hops). ──
  defmodule StubForge do
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_state_label(_r, _n, _s, _o), do: {:ok, :set}
    def set_assignee(_r, _n, login, _o), do: send(self(), {:assignee, login}) && {:ok, :set}
    def post_route(_r, _n, p, s, _o), do: send(self(), {:route, p, s}) && {:ok, :posted}
    def remove_label(_r, _n, _l, _o), do: send(self(), :unlocked) && {:ok, :removed}
    def close_issue(_r, _n, _o), do: send(self(), :closed) && {:ok, :closed}
    def count_signed_hops(_r, _n, opts), do: {:ok, Keyword.get(opts, :_hops, 0)}
  end

  defmodule DelivStub do
    def publish(_o), do: {:ok, %{commit_sha: "sha-x", pushed?: true, mode: :git_native}}
  end

  # Cartes 2 stages. `gated` : hard gate sur triage (exige result %{"ok"=>true}).
  # `soft` : soft gate sur triage. `plain` : aucune gate (advance pur).
  defmodule Carte do
    def load!("gated") do
      %{
        "name" => "gated",
        "stages" => %{
          "triage" => %{
            "role" => "architect",
            "needs" => [],
            "gate" => %{"type" => "hard", "rule" => %{"ok" => true}}
          },
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    def load!("soft") do
      %{
        "name" => "soft",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => [], "gate" => %{"type" => "soft"}},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    def load!("plain") do
      %{
        "name" => "plain",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end
  end

  defp hc(opts \\ []) do
    %HopConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      hop_completer: Fleet.Pilot.HopCompleter,
      forge_client: StubForge,
      loader: Carte,
      deliverable: DelivStub,
      max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2)
    }
  end

  # pod.completed du stage `triage` qui vient de finir, avec son `result`.
  defp triage_done(pipeline, result) do
    %{
      "ticket_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => "architect",
      "pipeline" => pipeline,
      "stage" => "triage",
      "result" => result
    }
  end

  test "gate :pass → avance vers build (engineer)" do
    assert {:ok, :reassigned} =
             HopConsumer.maybe_complete(triage_done("gated", %{"ok" => true}), hc())

    assert_received {:route, "gated", "build"}
    assert_received {:assignee, "engineer"}
    assert_received :unlocked
  end

  test "pas de gate sur le stage → avance (comportement A2 inchangé)" do
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(triage_done("plain", %{}), hc())
    assert_received {:route, "plain", "build"}
    assert_received {:assignee, "engineer"}
  end

  test "gate {:fail} sous budget → rebond vers le 1er stage (triage/architect)" do
    payload = triage_done("gated", %{})

    assert {:ok, :reassigned} = HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 0]))
    assert_received {:route, "gated", "triage"}
    assert_received {:assignee, "architect"}
    assert_received :unlocked
  end

  test "gate {:fail} mais budget épuisé → rework_exhausted, AUCUNE écriture forge" do
    # budget = nb_stages(2) * (max_rework_rounds(2) + 1) = 6
    payload = triage_done("gated", %{})

    assert {:error, {:rework_exhausted, %{hops: 6, budget: 6}}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))

    refute_received {:assignee, _}
    refute_received {:route, _, _}
    refute_received :unlocked
    refute_received :closed
  end

  test "budget : juste sous la limite rebondit, pile à la limite s'arrête" do
    payload = triage_done("gated", %{})
    # budget 6 : hops=5 rebondit, hops=6 stuck
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 5]))

    assert {:error, {:rework_exhausted, _}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))
  end

  test "soft gate → gate_pending (différé A2.3b), n'avance pas, ne déverrouille pas" do
    payload = triage_done("soft", %{})

    assert {:error, {:gate_pending, %{kind: :soft}}} = HopConsumer.maybe_complete(payload, hc())
    refute_received {:assignee, _}
    refute_received :unlocked
  end
end
