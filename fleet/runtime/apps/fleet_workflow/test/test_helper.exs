# Démarre l'app `fleet_workflow` (supervisor désormais VIDE — le moteur RAM `Executor` a été retiré,
# ②.3 / BL-050) + ses deps. Le broker `Fleet.TaskQueue` (dép fleet_task_queue) démarre app-global ici
# → les tests n'ont pas à le `start_supervised`, ils enqueue/get_for_pod sur le serveur canonique.
{:ok, _} = Application.ensure_all_started(:fleet_workflow)
ExUnit.start()
