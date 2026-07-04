defmodule Fleet.Observation.ReadModelTest do
  @moduledoc """
  ReadModel hermétique : `subscribe: false` (pas de bus réel), events injectés
  via `send/2`, barrière de synchro `:sys.get_state/1`. `async: false` — table
  ETS nommée + nom GenServer singleton (pas de parallélisme inter-modules).
  """
  use ExUnit.Case, async: false

  alias Fleet.Observation.ReadModel

  # `type` est passé en string par les call-sites (routage ReadModel par préfixe string) ;
  # le constructeur canonique veut un atom() → on convertit (String.to_atom, OK en test : set borné).
  # La projection re-stringifie le type, donc les assertions sur clés string restent valides.
  defp ev(type, opts) do
    Fleet.Event.new(Keyword.get(opts, :source, :spawner), String.to_atom(type),
      pod_id: Keyword.get(opts, :pod_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      payload: Keyword.get(opts, :payload, %{})
    )
  end

  defp sync(pid), do: :sys.get_state(pid)

  test "routage par préfixe : chaque event tombe dans le bon deck" do
    pid = start_supervised!({ReadModel, subscribe: false})

    send(pid, ev("work_item.completed", source: :task_queue))
    send(pid, ev("workflow_map.completed", source: :workflow))
    send(pid, ev("audit.verdict", source: :starfleet))
    send(pid, ev("coord.escalation_triggered", source: :coord))
    send(pid, ev("gitea.opened", source: :api))
    send(pid, ev("fleet.boot_complete", source: :coord))
    sync(pid)

    p = ReadModel.projection()
    assert p.total == 6
    assert p.counts["work_item.completed"] == 1
    assert [%{type: "workflow_map.completed"}] = p.workflow_runs
    # audit.verdict ET coord.escalation_* → deck gatekeeper (2 entrées)
    assert [%{type: "coord.escalation_triggered"}, %{type: "audit.verdict"}] = p.gatekeeper
    assert [%{type: "gitea.opened"}] = p.coordination
    assert [%{type: "fleet.boot_complete"}] = p.diagnostics
  end

  test "stream borné, newest-first" do
    pid = start_supervised!({ReadModel, subscribe: false})
    for i <- 1..150, do: send(pid, ev("tick", correlation_id: "n#{i}"))
    sync(pid)

    p = ReadModel.projection()
    assert p.total == 150
    assert length(p.stream) == 100
    # le plus récent (n150) en tête
    assert [%{correlation_id: "n150"} | _] = p.stream
  end

  test "projection JSON-encodable : le payload brut (non-encodable) est exclu" do
    pid = start_supervised!({ReadModel, subscribe: false})
    # payload avec un terme non-JSON (pid) → si summarize le gardait, Jason casse
    send(pid, ev("pod.failed", pod_id: "pod-1", payload: %{reason: {:boom, self()}}))
    sync(pid)

    p = ReadModel.projection()
    assert {:ok, _json} = Jason.encode(p)
    assert [%{type: "pod.failed", pod_id: "pod-1"}] = p.stream
  end

  test "projection/0 sans ReadModel démarré → vide (le deck ne crashe pas)" do
    # aucun ReadModel ici → table absente → rescue → projection vide
    assert %{total: 0, stream: [], counts: %{}} = ReadModel.projection()
  end
end
