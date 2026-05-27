# Démarre l'arbre de supervision fleet_pipeline (Registry, PodRegistry,
# ExecutorSupervisor) + ses deps — sinon start_pipeline/2 échoue
# (ExecutorSupervisor absent). Les tests qui poussent dans TaskQueue la
# démarrent eux-mêmes via start_supervised!(Fleet.MCP.TaskQueue).
{:ok, _} = Application.ensure_all_started(:fleet_pipeline)
ExUnit.start()
