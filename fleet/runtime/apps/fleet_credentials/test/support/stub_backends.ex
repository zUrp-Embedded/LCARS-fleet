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

defmodule Fleet.Credentials.OAuthRefresher.StubBackend do
  @moduledoc false

  @behaviour Fleet.Credentials.OAuthRefresher.Backend

  @impl Fleet.Credentials.OAuthRefresher.Backend
  def refresh(refresh_token) do
    parent = Application.get_env(:fleet_credentials, :stub_refresh_parent)
    if parent, do: send(parent, {:refresh_called, refresh_token})

    case Application.get_env(:fleet_credentials, :stub_refresh_reply) do
      nil -> {:error, :stub_not_set}
      reply -> reply
    end
  end

  def set_next_reply(reply) do
    Application.put_env(:fleet_credentials, :stub_refresh_reply, reply)
    :ok
  end

  def set_parent(pid) do
    Application.put_env(:fleet_credentials, :stub_refresh_parent, pid)
    :ok
  end

  def clear do
    Application.delete_env(:fleet_credentials, :stub_refresh_reply)
    Application.delete_env(:fleet_credentials, :stub_refresh_parent)
    :ok
  end
end
