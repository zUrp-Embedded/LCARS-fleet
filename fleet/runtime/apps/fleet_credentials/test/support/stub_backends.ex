defmodule Fleet.Credentials.PlanValidator.StubBackend do
  @moduledoc false

  @behaviour Fleet.Credentials.PlanValidator.Backend

  @impl Fleet.Credentials.PlanValidator.Backend
  def account_info(token) do
    case Application.get_env(:fleet_credentials, :stub_account_info) do
      %{^token => reply} -> reply
      _ -> {:error, :stub_not_set}
    end
  end

  def set_reply(token, reply) do
    current = Application.get_env(:fleet_credentials, :stub_account_info, %{})
    Application.put_env(:fleet_credentials, :stub_account_info, Map.put(current, token, reply))
    :ok
  end

  def clear do
    Application.delete_env(:fleet_credentials, :stub_account_info)
    :ok
  end
end
