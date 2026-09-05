defmodule Fleet.Pilot.AwaitsArchDrainTest do
  @moduledoc """
  JG-064 — un ticket qui sort du pipeline ne sort plus en silence.

  Quand une escalade d'architecte se resout, `StepRunConsumer` retire l'etiquette
  `lcars-awaits-arch`. Si ce retrait n'a pas lieu — metadonnees sans `repo`/`number`, ou
  `remove_label` en erreur — l'etiquette RESTE, et `StepDispatcher.decide/1` saute toute issue qui
  la porte (`{:skip, :awaits_arch}`). Le ticket quitte le pipeline definitivement et seule une
  intervention humaine le debloque.

  Le code ne disait que `Logger.warning`, et le commentaire de la branche d'erreur affirmait
  « poller may re-offer (no loss) » — ce que le dispatcher contredit : il ne re-offre pas, il passe.
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.StepRunConsumer

  defmodule ForgeDown do
    def remove_label(_r, _n, _l, _o), do: {:error, :forge_write_down}
  end

  # Spied on the label it removes: the stub runs INSIDE the GenServer, the pid rides in forge_opts.
  defmodule ForgeSpy do
    def remove_label(repo, number, label, opts) do
      send(opts[:test_pid], {:remove_label, repo, number, label})
      {:ok, :removed}
    end
  end

  defp start_consumer(forge) do
    test = self()

    {:ok, pid} =
      StepRunConsumer.start_link(
        name: :"drain_#{System.unique_integer([:positive])}",
        subscribe: false,
        repo: "o/r",
        forge_client: forge,
        forge_opts: [test_pid: test],
        escalate_fun: fn kind, subject, cause, sig, _opts ->
          send(test, {:escalated, kind, subject, cause, sig})
          {:ok, 1}
        end
      )

    pid
  end

  defp resolution_event(meta) do
    %Fleet.Event{
      source: :task_queue,
      type: :"work_item.completed",
      correlation_id: "corr-#{System.unique_integer([:positive])}",
      timestamp: DateTime.utc_now(),
      payload: %{metadata: meta}
    }
  end

  test "TEMOIN — metadonnees completes + forge OK : l'etiquette est retiree, aucune escalade" do
    pid = start_consumer(ForgeSpy)

    # The repo comes from the EVENT's metadata (the work item has no repo field), never from the
    # consumer's own `repo:` — hence a repo that is not the consumer's, so the two cannot be confused.
    send(pid, resolution_event(%{"awaits_arch" => true, "repo" => "fleet/proj", "number" => 7}))
    _ = settle(pid)

    assert_received {:remove_label, "fleet/proj", 7, "lcars-awaits-arch"}
    refute_received {:escalated, _, _, _, _}
  end

  test "TEMOIN — une completion qui n'est PAS une escalade d'architecte ne draine rien" do
    pid = start_consumer(ForgeSpy)

    send(pid, resolution_event(%{"gate_eval" => false}))
    _ = settle(pid)

    refute_received {:remove_label, _, _, _}
    refute_received {:escalated, _, _, _, _}
  end

  test "metadonnees SANS repo/number : incident, pas un warning perdu" do
    pid = start_consumer(ForgeSpy)

    send(pid, resolution_event(%{"awaits_arch" => true}))
    _ = settle(pid)

    assert_received {:escalated, :awaits_arch_stuck, "unknown", {:metadata_incomplete, _}, _sig},
                    "une escalade resolue sans repo/number a laisse le ticket hors du pipeline " <>
                      "sans autre trace qu'un log"
  end

  test "remove_label en ERREUR : incident nommant l'issue restee verrouillee" do
    pid = start_consumer(ForgeDown)

    send(pid, resolution_event(%{"awaits_arch" => true, "repo" => "o/r", "number" => 7}))
    _ = settle(pid)

    assert_received {:escalated, :awaits_arch_stuck, "o/r#7",
                     {:remove_label_failed, :forge_write_down}, "awaits_arch_stuck:o/r#7"},
                    "l'etiquette est restee posee et rien de durable ne le dit"
  end
end
