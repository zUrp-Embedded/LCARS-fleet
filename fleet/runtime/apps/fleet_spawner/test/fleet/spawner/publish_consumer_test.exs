defmodule Fleet.Spawner.PublishConsumerTest do
  @moduledoc """
  B10 C3 / #583 Sprint 1 — PublishConsumer subscribe filter +
  dispatch chain. `:subscribe` false + `:spawner` stub → async.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PublishConsumer

  defmodule StubSpawner do
    def spawn_pod(_cap_profile, ticket_id, opts) do
      send(Process.get(:test_pid), {:spawn_called, ticket_id, opts})
      {:ok, :stub_pod}
    end
  end

  defp start_consumer do
    Process.put(:test_pid, self())
    name = :"pc_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({PublishConsumer, name: name, subscribe: false, spawner: StubSpawner})

    {pid, name}
  end

  test "admin.spawn.request avec name absent → log warn, alive, count++" do
    {pid, _} = start_consumer()

    send(pid, %Fleet.Event{
      source: :api,
      type: :"admin.spawn.request",
      timestamp: DateTime.utc_now(),
      payload: %{}
    })

    # Mi14 : :sys.get_state = barrière FIFO (send traité avant) → pas de sleep arbitraire.
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "admin.spawn.request avec name ghost → CapProfile.load fail → log warn, alive" do
    {pid, _} = start_consumer()

    send(pid, %Fleet.Event{
      source: :api,
      type: :"admin.spawn.request",
      timestamp: DateTime.utc_now(),
      payload: %{"cap_profile_name" => "ghost-role-xyz"}
    })

    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "event autre que admin.spawn.request → ignore (alive, pas spawn_called)" do
    {pid, _} = start_consumer()

    send(pid, %Fleet.Event{
      source: :spawner,
      type: :"pod.drift",
      timestamp: DateTime.utc_now(),
      payload: %{}
    })

    send(pid, %Fleet.Event{
      source: :coord,
      type: :"coord.action_dispatched",
      timestamp: DateTime.utc_now(),
      payload: %{}
    })

    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
    refute_received {:spawn_called, _, _}
  end

  test "msg non-event : pas de crash" do
    {pid, _} = start_consumer()
    send(pid, :random)
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  describe "to_keyword/1 — anti atom-leak (finding Vulcan)" do
    test "clé connue (atom existant) convertie, clé inconnue ignorée (pas de String.to_atom)" do
      # :mandate existe (littéral compilé ci-dessous + option spawn_opts) → conservée
      assert PublishConsumer.to_keyword(%{"mandate" => "x"}) == [mandate: "x"]

      # clé jamais vue comme atome → to_existing_atom raise → filtrée (anti DoS table d'atomes)
      garbage = "atom_inexistant_zzz_#{System.unique_integer([:positive])}"
      assert PublishConsumer.to_keyword(%{garbage => 1}) == []
    end

    test "keyword list passe telle quelle ; autre → []" do
      assert PublishConsumer.to_keyword(mandate: 1) == [mandate: 1]
      assert PublishConsumer.to_keyword(nil) == []
    end

    test "liste NON keyword (tableau JSON décodé) → [] (défense en profondeur, plus gobée brute)" do
      # Un `opts` arrivé comme tableau JSON (`["module","fun"]` ou `[%{...}]`) n'est JAMAIS une keyword-list
      # (clés string → maps/scalaires). Avant, `to_keyword(list) = list` le rendait tel quel → opts arbitraires
      # injectés. Désormais filtré à []. (Le verrou principal reste l'allowlist d'admission de /api/admin/spawn.)
      assert PublishConsumer.to_keyword(["module", "fun"]) == []
      assert PublishConsumer.to_keyword([%{"pod_dir_root" => "/evil"}]) == []
      assert PublishConsumer.to_keyword([{"string_key", 1}]) == []
    end
  end
end
