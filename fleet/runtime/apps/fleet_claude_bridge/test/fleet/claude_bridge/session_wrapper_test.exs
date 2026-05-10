defmodule Fleet.ClaudeBridge.SessionWrapperTest do
  use ExUnit.Case, async: false

  alias Fleet.ClaudeBridge.SessionWrapper
  alias Fleet.ClaudeBridge.StubBackends

  setup do
    original = Application.get_env(:fleet_claude_bridge, :session_backend)

    on_exit(fn ->
      if original do
        Application.put_env(:fleet_claude_bridge, :session_backend, original)
      else
        Application.delete_env(:fleet_claude_bridge, :session_backend)
      end
    end)

    :ok
  end

  describe "default backend (NotWiredYet, post-pod-1.18 pas câblé)" do
    test "new/1 retourne {:error, :not_wired_yet}" do
      Application.delete_env(:fleet_claude_bridge, :session_backend)

      assert {:error, :not_wired_yet} = SessionWrapper.new()
    end

    test "send/2 retourne {:error, :not_wired_yet}" do
      ref = %{adapter: :port, opaque: :ignored}
      Application.delete_env(:fleet_claude_bridge, :session_backend)

      assert {:error, :not_wired_yet} = SessionWrapper.send(ref, :anything)
    end
  end

  describe "wrap permissif via stub backend" do
    setup do
      Application.put_env(:fleet_claude_bridge, :session_backend, StubBackends.SessionEcho)
      :ok
    end

    test "new/1 wrappe la valeur backend dans une ref opaque adapter:port" do
      assert {:ok, %{adapter: :port, opaque: {:fake_pid, [foo: :bar]}}} =
               SessionWrapper.new(foo: :bar)
    end

    test "send/2 unwrappe l'opaque et délègue au backend" do
      {:ok, ref} = SessionWrapper.new([])
      assert :ok = SessionWrapper.send(ref, {:user_msg, "ping"})
    end
  end

  describe "propagation erreurs backend" do
    test "new/1 propage {:error, reason} sans wrap" do
      Application.put_env(:fleet_claude_bridge, :session_backend, StubBackends.SessionFailing)

      assert {:error, :stub_fail} = SessionWrapper.new([])
    end
  end
end
