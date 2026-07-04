defmodule Fleet.Pilot.StubTaskQueue do
  @moduledoc """
  Stub neutre du broker TaskQueue (seam `task_queue:` du dispatcher / consumer / chain) —
  dédup B6 : trois copies locales posaient le même contrat sous trois noms (`TQStub`,
  `StubQueue`, `StubTaskQueue`). Nom canon : `Stub<X>` pour un stub neutre.

  `enqueue/2` réussit toujours : signale `{:enqueued, pod_id, attrs}` au process du test
  (l'appelant tourne dans le même process) et rend l'id FIXE `"corr-1"` — les tests d'escalade
  gate s'en servent comme correlation_id attendu (`{:escalate, "corr-1", _}`, clés de
  `gate_evals`).
  """
  def enqueue(pod_id, attrs) do
    send(self(), {:enqueued, pod_id, attrs})
    {:ok, %{id: "corr-1"}}
  end
end
