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

    send(pid, {:"admin.spawn.request", %{"payload" => %{}, "ticket_id" => "T1"}})

    Process.sleep(30)
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "admin.spawn.request avec name ghost → CapProfile.load fail → log warn, alive" do
    {pid, _} = start_consumer()

    send(
      pid,
      {:"admin.spawn.request",
       %{"payload" => %{"cap_profile_name" => "ghost-role-xyz"}, "ticket_id" => "T2"}}
    )

    Process.sleep(30)
    assert Process.alive?(pid)
    assert %{count: 1} = :sys.get_state(pid)
    refute_received {:spawn_called, _, _}
  end

  test "event autre que admin.spawn.request → ignore (alive, pas spawn_called)" do
    {pid, _} = start_consumer()

    send(pid, {:"pod.drift", %{"payload" => %{}}})
    send(pid, {:"some.other", %{"payload" => %{}}})

    Process.sleep(30)
    assert Process.alive?(pid)
    refute_received {:spawn_called, _, _}
  end

  test "msg non-event : pas de crash" do
    {pid, _} = start_consumer()
    send(pid, :random)
    Process.sleep(20)
    assert Process.alive?(pid)
  end
end
