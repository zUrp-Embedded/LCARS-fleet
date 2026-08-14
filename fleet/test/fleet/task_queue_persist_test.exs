defmodule Fleet.TaskQueue.PersistTest do
  # async: false — global capture_log (logger backend swap): isolation away from concurrent tests.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  # F-007: a state.json write failure does not degrade SILENTLY. It is logged **error**
  # (durability of the recovery point broken) AND the broker SURVIVES (no crash: a disk blip
  # must not kill in-flight work items; reconciliation via the forge-driven rail).
  test "persist write fails → Logger.error (loud) + broker survives", %{tmp_dir: tmp_dir} do
    topic = "fleet.events.test.f007.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)

    # state_path whose parent is a regular FILE → `File.mkdir_p!` raises → persist rescue.
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "x")
    bad_path = Path.join([blocker, "nested", "state.json"])

    {:ok, q} =
      start_supervised({Server, name: nil, topic: topic, state_path: bad_path}, id: :q_f007)

    log =
      capture_log(fn ->
        assert {:ok, _task} = TaskQueue.enqueue(q, "pod-A", %{brief: "fix X"})

        # enqueue → synchronous handle_call → persist attempts the write → failure logged before the reply.
      end)

    assert log =~ "persist FAILED"
    assert log =~ "durability"

    # the broker did NOT crash: the work item is still served from RAM.
    assert {:ok, %{state: :assigned}} = TaskQueue.get_for_pod(q, "pod-A")
  end

  # 6-017 — `Store.default_path/0` porte un `System.user_home!()`, et son UNIQUE appelant le payait
  # a chaque `init/1` : le 3e argument de `Keyword.get/3` est un argument ordinaire, evalue que la
  # cle soit posee ou non. En production le broker tourne EPHEMERE (`persist: false`), donc un HOME
  # irresolvable levait au demarrage pour un chemin que rien n'aurait lu.
  #
  # ⚠ CE QUI EST OBSERVE ICI EST L'APPEL, PAS SON RESULTAT. On ne peut pas fabriquer le HOME
  # irresolvable depuis un test : `System.user_home!/0` ne relit pas `$HOME` a l'appel — la valeur
  # est resolue au demarrage de la VM (mesure : `System.delete_env("HOME")` ne change rien a ce
  # qu'elle rend). Assertion sur `state_path` seule ne prouverait rien non plus : `nil` pourrait
  # venir d'une resolution faite puis jetee. La trace repond a la vraie question — la fonction
  # a-t-elle tourne.
  describe "6-017 — un defaut qui coute ne tourne que s'il EST la reponse" do
    setup do
      # Pose la cle : `default_path/0` rend alors le chemin configure SANS toucher au home reel, et
      # reste comptee par la trace. Le test parle de l'APPEL, pas de ce qu'il calcule.
      tmp = Path.join(System.tmp_dir!(), "tq6017-#{System.unique_integer([:positive])}.json")
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :task_queue_state_path, tmp)
      {:ok, configured: tmp}
    end

    # Le processus tracant est EXCLU du tracage : le compte ne serait rendu que par un tiers. Ici
    # `init/1` tourne dans le GenServer, un autre processus que le test — la mesure est valide, et
    # le temoin ci-dessous est ce qui le prouve plutot que de le supposer.
    defp default_path_calls(fun) do
      # ⚠ `trace_pattern` REND 0 ET N'ARME RIEN SUR UN MODULE PAS ENCORE CHARGE, en silence. Les
      # modules Elixir se chargent a la demande : `Store` n'avait jamais ete touche par ce fichier
      # de test, donc le motif ne matchait aucune fonction et les trois tests comptaient zero — dont
      # les deux qui ATTENDENT zero. C'est le temoin ci-dessous qui l'a dit, pas la suite.
      Code.ensure_loaded!(Fleet.TaskQueue.Store)

      assert :erlang.trace_pattern({Fleet.TaskQueue.Store, :default_path, 0}, true, [:local]) ==
               1,
             "le motif de trace n'a arme aucune fonction — la mesure qui suit serait vide"

      :erlang.trace(:all, true, [:call])

      try do
        result = fun.()
        :erlang.trace(:all, false, [:call])
        {result, drain_calls(0)}
      after
        :erlang.trace_pattern({Fleet.TaskQueue.Store, :default_path, 0}, false, [:local])
      end
    end

    defp drain_calls(n) do
      receive do
        {:trace, _pid, :call, {Fleet.TaskQueue.Store, :default_path, []}} -> drain_calls(n + 1)
      after
        50 -> n
      end
    end

    test "TEMOIN — persist: true sans :state_path APPELLE le defaut (l'instrument tire)", %{
      configured: tmp
    } do
      {pid, calls} =
        default_path_calls(fn ->
          {:ok, pid} = start_supervised({Server, name: nil, persist: true}, id: :q6017_witness)
          pid
        end)

      assert calls == 1, "sans temoin, un compte de 0 ci-dessous ne prouverait rien"
      assert :sys.get_state(pid).state_path == tmp
    end

    test "persist: false sans :state_path → le defaut n'est PAS resolu" do
      {pid, calls} =
        default_path_calls(fn ->
          {:ok, pid} = start_supervised({Server, name: nil, persist: false}, id: :q6017_ephemeral)
          pid
        end)

      assert calls == 0
      # `nil` n'est pas une valeur nouvelle : `persist/1` et `load_state/2` la traitent deja.
      assert :sys.get_state(pid).state_path == nil
    end

    test "un :state_path explicite → le defaut n'est PAS resolu non plus", %{tmp_dir: tmp_dir} do
      given = Path.join(tmp_dir, "explicite.json")

      {pid, calls} =
        default_path_calls(fn ->
          {:ok, pid} =
            start_supervised({Server, name: nil, persist: true, state_path: given},
              id: :q6017_explicit
            )

          pid
        end)

      assert calls == 0
      assert :sys.get_state(pid).state_path == given
    end
  end
end
