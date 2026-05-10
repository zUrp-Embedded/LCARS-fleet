defmodule Fleet.ClaudeBridge.StubBackends do
  @moduledoc """
  Stubs des Backend behaviours pour swap test runtime.

  Couvre :
    * `Fleet.ClaudeBridge.PermissionAdapter.Backend`
    * `Fleet.ClaudeBridge.SessionWrapper.Backend`
    * `Fleet.ClaudeBridge.MCPRouter.Backend`

  Comportements paramétrés via `Application.get_env/3` ou simples
  retours statiques selon le besoin du test (cf `setup` block).
  """

  defmodule PermissionAlwaysAllow do
    @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

    @impl true
    def can_use_tool(_tool_name, _tool_input, _context), do: :allow
  end

  defmodule PermissionAllowAugmented do
    @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

    @impl true
    def can_use_tool(_tool_name, _tool_input, _context),
      do: {:allow, %{"augmented" => true}}
  end

  defmodule PermissionDeny do
    @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

    @impl true
    def can_use_tool(_tool_name, _tool_input, _context),
      do: {:deny, "stub-deny"}
  end

  defmodule PermissionAsk do
    @behaviour Fleet.ClaudeBridge.PermissionAdapter.Backend

    @impl true
    def can_use_tool(_tool_name, _tool_input, _context), do: :ask
  end

  defmodule SessionEcho do
    @behaviour Fleet.ClaudeBridge.SessionWrapper.Backend

    @impl true
    def new(opts), do: {:ok, {:fake_pid, opts}}

    @impl true
    def send(_opaque, _msg), do: :ok
  end

  defmodule SessionFailing do
    @behaviour Fleet.ClaudeBridge.SessionWrapper.Backend

    @impl true
    def new(_opts), do: {:error, :stub_fail}

    @impl true
    def send(_opaque, _msg), do: {:error, :stub_fail}
  end

  defmodule MCPDispatcher do
    @behaviour Fleet.ClaudeBridge.MCPRouter.Backend

    @impl true
    def dispatch(topic, payload) do
      send(self(), {:dispatched, topic, payload})
      :ok
    end
  end

  defmodule MCPFailing do
    @behaviour Fleet.ClaudeBridge.MCPRouter.Backend

    @impl true
    def dispatch(_topic, _payload), do: {:error, :stub_fail}
  end
end
