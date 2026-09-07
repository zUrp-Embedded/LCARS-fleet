defmodule Fleet.Pilot.CompletionOutboxReplayTest do
  @moduledoc """
  6-127 — LA CHAINE INTERROMPUE REPREND, SANS NOUVEAU RUN D'AGENT.

  La preuve de sortie de la fiche nomme trois points de mort — avant push, apres push avant PR,
  apres PR avant unlock — et demande qu'a chacun, apres redemarrage du BEAM, « le meme resultat
  reprenne sans nouveau run agent, converge exactement une fois ».

  ⚠ CE QUI EST PROUVE ICI, ET CE QUI L'EST AILLEURS. Les trois points sont a l'INTERIEUR de la
  chaine de `StepRunCompleter`, dont l'ordre et l'idempotence sont deja concus pour ca (verrou leve
  EN DERNIER, dedup du commentaire par signature, push idempotent) et tenus par ses propres tests.
  Vu du consommateur, les trois rendent la meme chose : `{:error, _}`. Ce fichier tient la moitie
  qui MANQUAIT — que le resultat SURVIVE a l'interruption et soit REJOUE a l'identique. Rejouer
  n'est utile que parce que l'autre moitie existe ; l'affirmer sans la nommer serait s'en attribuer
  le merite.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.CompletionOutbox
  alias Fleet.Pilot.StepRunConsumer

  # Completer qui MEURT : c'est ce que voit le consommateur quand la Task de completion casse a
  # n'importe lequel des trois points.
  defmodule CompleterQuiMeurt do
    def complete_pr(_step_run, _opts), do: {:error, :task_morte}
    def await_arch(_step_run, _opts), do: {:error, :task_morte}
  end

  # Completer qui ABOUTIT, et qui rapporte au test CE QU'IL A RECU — pour prouver que la reprise
  # rejoue le MEME resultat d'agent, pas un nouveau.
  defmodule CompleterQuiAboutit do
    def complete_pr(step_run, _opts) do
      if obs = Process.whereis(:outbox_replay_observer), do: send(obs, {:complete, step_run})
      {:ok, :fait}
    end

    def await_arch(_step_run, _opts), do: {:ok, :awaiting_arch}
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp state(completer) do
    %StepRunConsumer{
      repo: "lordzurp/lcars-test",
      remote: "origin",
      forge_opts: [base_url: "http://192.0.2.10"],
      role_emails: fn role -> ["#{role}@lcars.local"] end,
      step_run_completer: completer,
      deliverable_mode_fun: dmode()
    }
  end

  defp payload do
    %{
      "pod_id" => "pod-abc",
      "work_item_id" => "wi-6127",
      "issue_id" => "issue-42",
      "result" => %{"ok" => true, "empreinte" => "LE-TRAVAIL-DE-L-AGENT"},
      "workspace" => "/pods/pod-abc/workspace",
      "base_sha" => "cafe1234",
      "base_branch" => "main",
      "role" => "engineer"
    }
  end

  defp evenement, do: Fleet.Event.new(:spawner, :"pod.completed", payload: payload())

  setup do
    root = Fleet.TestEnv.tmp_path("outbox-replay")
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_completion_outbox_root, root)
    on_exit(fn -> File.rm_rf(root) end)
    :ok
  end

  test "chaine interrompue -> le resultat RESTE du ; reprise -> meme resultat, journal vide" do
    # 1. La chaine casse. Avant 6-127 le resultat etait consomme et perdu ici meme.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:noreply, _} = StepRunConsumer.handle_info(evenement(), state(CompleterQuiMeurt))
    end)

    assert [%{"work_item_id" => "wi-6127"} = du] = CompletionOutbox.pending(),
           "une completion interrompue doit rester DUE — sinon le travail de l'agent est perdu"

    assert get_in(du, ["result", "empreinte"]) == "LE-TRAVAIL-DE-L-AGENT",
           "c'est le RESULTAT qui doit survivre, pas seulement un marqueur"

    # 2. Redemarrage : le consommateur rejoue ce qui reste du.
    # Pas d'`on_exit` pour desenregistrer : le nom se libere avec le processus de test, et un
    # `unregister` pose la leve « not a pid » puisqu'il tourne APRES sa mort. Meme famille que la
    # course `whereis` puis `stop` fermee ailleurs aujourd'hui.
    Process.register(self(), :outbox_replay_observer)

    assert {:noreply, _} =
             StepRunConsumer.handle_info(:replay_completion_outbox, state(CompleterQuiAboutit))

    # LA MEME CHARGE UTILE est repassee au completer — aucun agent n'a retravaille. Le `step_run`
    # est DERIVE de la charge (il n'en porte pas le `result` brut), donc on epingle ce qui en vient
    # et qui identifie cette completion-la : le pod d'origine et le sha d'entree de sa provenance.
    # La survie du RESULTAT lui-meme est prouvee juste au-dessus, sur l'entree du journal.
    assert_received {:complete, step_run}
    assert step_run.pod_id == "pod-abc"
    assert step_run.deliverable_opts.provenance.input_sha == "cafe1234"

    # 3. Acquittee, donc plus due : une seconde reprise ne referait rien.
    assert CompletionOutbox.pending() == []
  end

  test "chaine qui ABOUTIT du premier coup -> rien ne reste du" do
    # Pas d'`on_exit` pour desenregistrer : le nom se libere avec le processus de test, et un
    # `unregister` pose la leve « not a pid » puisqu'il tourne APRES sa mort. Meme famille que la
    # course `whereis` puis `stop` fermee ailleurs aujourd'hui.
    Process.register(self(), :outbox_replay_observer)

    assert {:noreply, _} = StepRunConsumer.handle_info(evenement(), state(CompleterQuiAboutit))
    assert_received {:complete, _}
    assert CompletionOutbox.pending() == []
  end

  # TEMOIN — sans lui, un `pending/0` qui rendrait TOUJOURS `[]` passerait le test ci-dessus, et
  # celui d'au-dessus passerait si la reprise ne rejouait rien mais effacait quand meme.
  test "TEMOIN — la reprise sur un journal VIDE ne fabrique aucune completion" do
    # Pas d'`on_exit` pour desenregistrer : le nom se libere avec le processus de test, et un
    # `unregister` pose la leve « not a pid » puisqu'il tourne APRES sa mort. Meme famille que la
    # course `whereis` puis `stop` fermee ailleurs aujourd'hui.
    Process.register(self(), :outbox_replay_observer)

    assert CompletionOutbox.pending() == []

    assert {:noreply, _} =
             StepRunConsumer.handle_info(:replay_completion_outbox, state(CompleterQuiAboutit))

    refute_received {:complete, _}
  end

  # ⚖ Pinned as it IS (2026-09-05): a completion the consumer SKIPS (no project on the payload) is
  # not owed to anyone, so its entry leaves the journal at once.
  test "un pod.completed SANS projet est acquitte : {:skip, _} retire l'entree du journal" do
    sans_projet =
      Fleet.Event.new(:spawner, :"pod.completed", payload: Map.delete(payload(), "workspace"))

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:noreply, _} = StepRunConsumer.handle_info(sans_projet, state(CompleterQuiMeurt))
    end)

    assert CompletionOutbox.pending() == []
  end
end
