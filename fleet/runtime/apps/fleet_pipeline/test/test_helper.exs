# Démarre l'arbre de supervision fleet_pipeline (Registry, PodRegistry,
# ExecutorSupervisor) + ses deps — sinon start_pipeline/2 échoue
# (ExecutorSupervisor absent). Le broker `Fleet.TaskQueue` (dép
# fleet_task_queue) démarre app-global ici même → les tests n'ont pas à le
# start_supervised, ils enqueue/get_for_pod sur le serveur canonique.
{:ok, _} = Application.ensure_all_started(:fleet_pipeline)
# Tests R1 (couture) tagués :r1_seam — ROUGES tant que R2-R7 ne sont pas landés.
# Exclus du run par défaut (la détection de régression reste lisible) ; lancés
# via `mix test --only r1_seam`. Exclusion retirée au verrou R7 (ils virent au vert).
ExUnit.start(exclude: [:r1_seam])
