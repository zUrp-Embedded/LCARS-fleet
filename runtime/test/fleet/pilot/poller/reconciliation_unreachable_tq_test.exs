defmodule Fleet.Pilot.Poller.ReconciliationUnreachableTqTest do
  use ExUnit.Case, async: false
  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.Poller.Reconciliation.Seams

  # JG-074 — la file de taches est un POINT DE SERIALISATION PARTAGE : `pod_status/1` est un
  # `GenServer.call` sans timeout explicite (donc 5 s) vers un serveur unique que tous les pods
  # interrogent. Un redemarrage par son superviseur, ou une pointe de charge, et l'appel `exit`.
  #
  # Avant le fix, ce silence devenait `false` — indistinguable de « ce pod n'a pas de tache » — et
  # le pod partait au reap. Un pod peut-etre EN TRAIN DE TRAVAILLER, tue pour l'indisponibilite
  # d'un autre.
  #
  # Les deux tests vont par paire et le premier est le garde-fou du second : sans lui, faire
  # disparaitre le reap suffirait a rendre le second vert.

  @repo "o/r"
  # `Fleet.PodId.parse_ref/2` exige le prefixe du depot : `o/r` -> `o-r-`.
  @pod_id "o-r-issue-7-engineer"

  defmodule KillSpy do
    def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
    def kill_pod(pod_id), do: Agent.update(:jg074_kills, &[pod_id | &1])
  end

  defmodule TqIdle do
    # La file REPOND : aucun work item pour ce pod. Orphelin etabli.
    def list_active, do: []
    def pod_active_issue_id(_), do: {:ok, nil}
    def pod_status(_), do: {:ok, nil}
  end

  defmodule TqUnreachable do
    # La file NE REPOND PAS — la forme exacte d'un `GenServer.call` vers un serveur mort.
    def list_active, do: []
    def pod_active_issue_id(_), do: {:ok, nil}

    def pod_status(_),
      do: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
  end

  defmodule Forge do
    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def stop_stopwatch(_r, _n, _o), do: :ok
  end

  setup do
    # ⚠ `start_link` NE SUFFISAIT PAS, ET LE BANC L'A DIT (run 99, 2026-08-14) :
    # `{:error, {:already_started, #PID<…>}}` dans ce `setup`.
    #
    # Le lien tue bien l'agent avec le test, mais la mort est ASYNCHRONE : le test suivant peut
    # entrer dans son `setup` avant que le nom `:jg074_kills` ne soit libere par le registre. Un
    # `start_link` nomme depuis un `setup` est donc une course avec le test precedent — invisible
    # ici, intermittente au banc, et elle accuse le sujet plutot que la mise en scene.
    #
    # `start_supervised!` la ferme par construction : ExUnit arrete ses enfants et ATTEND leur
    # terminaison avant le test suivant. C'est la raison d'etre du superviseur de test, pas un
    # confort.
    start_supervised!(%{
      id: :jg074_kills,
      start: {Agent, :start_link, [fn -> [] end, [name: :jg074_kills]]}
    })

    :ok
  end

  defp reconcile_with(tq) do
    seams = %Seams{
      forge: Forge,
      spawner: KillSpy,
      task_queue: tq,
      repo: @repo,
      forge_opts: []
    }

    # Le suspect est deja confirme : la grace de 2 ticks est satisfaite, donc CE tick agit.
    prior = MapSet.new([{@repo, :pod, @pod_id}])
    pods = Reconciliation.snapshot_pods(KillSpy)
    _ = Reconciliation.reconcile([], [], MapSet.new(), prior, seams, pods)
    Agent.get(:jg074_kills, & &1)
  end

  test "file JOIGNABLE et pod sans tache : le reap a bien lieu (le devoir n'est pas neutralise)" do
    assert reconcile_with(TqIdle) == [@pod_id],
           "le reap nominal ne se declenche plus — le second test ne prouverait plus rien"
  end

  test "file INJOIGNABLE : aucun reap, le pod est reporte au prochain tick" do
    assert reconcile_with(TqUnreachable) == [],
           "un pod a ete reape alors que la file n'a pas repondu — " <>
             "l'indisponibilite d'un tiers est devenue un verdict sur ce pod"
  end

  # ⚠ CE TEST-CI EST LE SEUL DES TROIS QUI DISCRIMINE ENCORE, et c'est un balayage de mutation
  # retro-actif qui l'a dit : annuler le correctif JG-074 laisse les deux tests ci-dessus VERTS.
  #
  # La raison n'est pas qu'ils etaient creux — c'est que la propriete a MIGRE D'UN CRAN. JG-083 a
  # rendu `live_owned_refs/2` capable de dire `:error`, et `reconcile_with_pods/6` rend alors
  # `prior_suspects` SANS RIEN FAIRE : sur une file franchement muette, la passe n'atteint plus
  # jamais le devoir de reap. La garde de JG-074 est intacte, elle est simplement devenue
  # INATTEIGNABLE par le scenario que ses deux tests mettent en scene — donc plus rien ne la
  # verifie, et une regression du trois-etats vers le booleen ne rougirait nulle part.
  #
  # Ce qu'elle couvre encore, et que celui-ci met en scene : le TRANSITOIRE QUI TOMBE ENTRE LES DEUX
  # LECTURES. `live_owned_refs/2` et `quiesced_brick_pods/4` interrogent la file a deux moments
  # distincts ; une file qui repond au premier et meurt avant le second passe la garde de niveau
  # passe et arrive au devoir de reap. C'est exactement la ou le pliage de l'inconnu sur `false`
  # tuait un pod au travail.
  describe "la garde de JG-074 couvre le transitoire qui tombe ENTRE les deux lectures" do
    defmodule TqDiesBetweenReads do
      # Repond a la lecture de PROPRIETE (la passe continue, pas de fail-safe global), puis meurt
      # avant la lecture du devoir de REAP. Un compteur, parce que les deux lectures passent par le
      # MEME `pod_status/1` : c'est le rang de l'appel qui les distingue, pas leur nom.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, nil}

      def pod_status(_) do
        n = Agent.get_and_update(:jg074_calls, &{&1 + 1, &1 + 1})

        if n <= 1,
          do: {:ok, nil},
          else: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
      end
    end

    setup do
      # Meme course que le `setup` du module — cf. son commentaire.
      start_supervised!(%{
        id: :jg074_calls,
        start: {Agent, :start_link, [fn -> 0 end, [name: :jg074_calls]]}
      })

      :ok
    end

    test "la file meurt entre les deux lectures : AUCUN reap" do
      assert reconcile_with(TqDiesBetweenReads) == [],
             "la file a repondu a la lecture de propriete puis est morte : le devoir de reap a " <>
               "quand meme conclu « ce pod n'a pas de tache » et l'a tue"

      # La mise en scene est verifiee, pas supposee : sans les DEUX lectures, le test ne prouve
      # rien de ce que son titre annonce.
      assert Agent.get(:jg074_calls, & &1) >= 2,
             "la file n'a ete lue qu'une fois — le scenario « meurt entre les deux » n'a pas eu lieu"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  # JG-120 — LA LIGNE ANNONCAIT « reaped » AU PASSE, AVANT L'APPEL. Elle etait vraie de l'INTENTION
  # et jamais du fait : `safe_kill/2` avale par conception, et un operateur qui grep `reaped` lisait
  # un kill accompli la ou il n'y avait qu'un kill tente. L'avalement reste (le tick suivant
  # re-suspecte) ; c'est la TRACE qui suit desormais l'acte.
  describe "JG-120 — la trace du reap suit l'acte au lieu de le preceder" do
    defmodule KillFails do
      def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
      def kill_pod(_pod_id), do: {:error, :boom}
    end

    defmodule KillRaises do
      def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
      def kill_pod(_pod_id), do: raise("le backend de kill est casse")
    end

    defp reap_with(spawner) do
      seams = %Seams{
        forge: Forge,
        spawner: spawner,
        task_queue: TqIdle,
        repo: @repo,
        forge_opts: []
      }

      prior = MapSet.new([{@repo, :pod, @pod_id}])
      pods = Reconciliation.snapshot_pods(spawner)

      ExUnit.CaptureLog.capture_log(fn ->
        _ = Reconciliation.reconcile([], [], MapSet.new(), prior, seams, pods)
      end)
    end

    test "un kill qui ECHOUE ne s'annonce plus comme accompli" do
      log = reap_with(KillFails)

      refute log =~ "→ REAPED",
             "la trace annonce un reap accompli alors que le kill a rendu une erreur"

      assert log =~ "did NOT land", "l'echec du kill n'apparait nulle part"
      assert log =~ "re-suspects and retries", "la trace ne dit pas que rien n'est bloque"
    end

    test "un kill qui LEVE non plus — `safe_kill/2` ne fabrique plus un `:ok`" do
      log = reap_with(KillRaises)

      refute log =~ "→ REAPED"
      assert log =~ "kill_raised", "l'exception est repliee sur un succes quelque part"
    end

    test "TEMOIN — un kill qui REUSSIT s'annonce bien, sinon le test d'a cote ne prouve rien" do
      log = reap_with(KillSpy)

      assert log =~ "→ REAPED"
      refute log =~ "did NOT land"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════
  # JG-083 — LE MEME SILENCE, SUR L'AUTRE DEVOIR, ET LE FIX DE JG-074 NE LE COUVRAIT PAS.
  #
  # JG-074 a fait rendre `:unknown` a `pod_task_state/2` — mais cette fonction ne sert que le devoir
  # « reap des pods quiesces ». Le devoir de PROPRIETE DES VERROUS passe par `live_owned_refs/2`, qui
  # porte bien un `rescue _ -> :error`, et dont les DEUX helpers interceptaient l'exception avant
  # elle : `pod_pulled?/2` rendait `false`, `project_pod_owned_refs/3` rendait `[]`. Un redemarrage
  # de la file se lisait donc « ce pod ne possede rien » → son verrou entrait dans `orphaned_now` →
  # le verrou d'un pod VIVANT etait reclame, le ticket re-depeche, et le pod initial detruit.
  #
  # La garde existait. Les deux `rescue` les plus internes l'annulaient.
  describe "JG-083 — propriete des verrous : l'indisponibilite de la file n'est pas une absence" do
    defmodule TqOwnerUnreachable do
      # Le pod POSSEDE le verrou de l'issue 7 — mais la file ne peut pas le dire.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, "issue-7"}

      def pod_status(_),
        do: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
    end

    defmodule TqOwnerIdle do
      # La file REPOND : ce pod n'a pulle aucune tache. Le verrou est un vrai orphelin.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, nil}
      def pod_status(_), do: {:ok, nil}
    end

    defmodule ReclaimSpy do
      def remove_label(_r, n, l, _o), do: Agent.update(:jg083_reclaims, &[{n, l} | &1])
      def stop_stopwatch(_r, _n, _o), do: :ok
    end

    setup do
      # Meme course que le `setup` du module — cf. son commentaire.
      start_supervised!(%{
        id: :jg083_reclaims,
        start: {Agent, :start_link, [fn -> [] end, [name: :jg083_reclaims]]}
      })

      :ok
    end

    defp reclaims_with(tq) do
      seams = %Seams{
        forge: ReclaimSpy,
        spawner: KillSpy,
        task_queue: tq,
        repo: @repo,
        forge_opts: []
      }

      # Une issue VERROUILLEE (`lcars-in-flight`), deja suspecte au tick precedent : la grace de
      # 2 ticks est satisfaite, donc CE tick reclame — sauf si la propriete est indeterminee.
      issues = [PayloadFixture.issue(number: 7, label_names: ["lcars-in-flight"])]
      prior = MapSet.new([{@repo, :issue, 7}])
      pods = Reconciliation.snapshot_pods(KillSpy)
      _ = Reconciliation.reconcile(issues, [], MapSet.new(), prior, seams, pods)
      Agent.get(:jg083_reclaims, & &1)
    end

    test "TEMOIN — file JOIGNABLE et pod sans tache pullee : le verrou est bien reclame" do
      assert reclaims_with(TqOwnerIdle) != [],
             "le reclaim nominal ne se declenche plus — le second test ne prouverait plus rien"
    end

    test "file INJOIGNABLE : AUCUN reclaim, le verrou du pod vivant est preserve" do
      assert reclaims_with(TqOwnerUnreachable) == [],
             "le verrou d'un pod vivant a ete reclame parce que la file n'a pas repondu — " <>
               "l'indisponibilite d'un tiers est devenue un verdict de propriete"
    end
  end
end
