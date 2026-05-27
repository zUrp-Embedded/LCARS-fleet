defmodule Fleet.PodRuntime.SDKPortBackend do
  @moduledoc """
  Behaviour wrap des opérations Port BEAM consommées par
  `Fleet.PodRuntime.TurnDispatcher`.

  Surface SDK ciblée : `ClaudeCode.Adapter.Port.*` (Port lifecycle +
  write/read NDJSON). Wrap permet swap stub côté tests + différer le
  câblage SDK tant que pod 1.14 (cf moduledoc `Fleet.PodRuntime`).

  Default backend `NotWiredYet` retourne `{:error, :not_wired_yet}`
  jusqu'à ce que `:claude_code` soit introduit (post-pod-1.18).
  """

  @callback write(port_ref :: term(), payload :: iodata()) :: :ok | {:error, term()}
end

defmodule Fleet.PodRuntime.SDKPortBackend.NotWiredYet do
  @moduledoc """
  Backend placeholder. Le wiring SDK réel `ClaudeCode.Adapter.Port.*`
  se fait post-upgrade pod env Elixir 1.18 + introduction `:claude_code`
  dep (cf `Fleet.PodRuntime` moduledoc).
  """

  @behaviour Fleet.PodRuntime.SDKPortBackend

  @impl Fleet.PodRuntime.SDKPortBackend
  def write(_port_ref, _payload), do: {:error, :not_wired_yet}
end
