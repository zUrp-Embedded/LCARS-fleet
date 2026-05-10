defmodule Fleet.Credentials.PlanValidatorTest do
  use ExUnit.Case, async: false

  alias Fleet.Credentials.PlanValidator
  alias Fleet.Credentials.PlanValidator.StubBackend

  setup do
    prev = Application.get_env(:fleet_credentials, :plan_validator_backend)
    Application.put_env(:fleet_credentials, :plan_validator_backend, StubBackend)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:fleet_credentials, :plan_validator_backend)
        v -> Application.put_env(:fleet_credentials, :plan_validator_backend, v)
      end
    end)

    :ok
  end

  test "pro plan returns :ok" do
    StubBackend.set_reply("tok-pro", {:ok, %{"subscription_type" => "pro"}})
    assert :ok = PlanValidator.validate_plan("tok-pro")
    StubBackend.clear()
  end

  test "max plan returns :ok" do
    StubBackend.set_reply("tok-max", {:ok, %{"subscription_type" => "max"}})
    assert :ok = PlanValidator.validate_plan("tok-max")
    StubBackend.clear()
  end

  test "free plan returns invalid_plan" do
    StubBackend.set_reply("tok-free", {:ok, %{"subscription_type" => "free"}})

    assert {:error, {:invalid_plan, "free"}} = PlanValidator.validate_plan("tok-free")
    StubBackend.clear()
  end

  test "atom plan returned by SDK is stringified" do
    StubBackend.set_reply("tok-atom", {:ok, %{"subscription_type" => :enterprise}})
    assert {:error, {:invalid_plan, "enterprise"}} = PlanValidator.validate_plan("tok-atom")
    StubBackend.clear()
  end

  test "SDK error returns account_info_failed" do
    StubBackend.set_reply("tok-broken", {:error, :network_timeout})

    assert {:error, {:account_info_failed, :network_timeout}} =
             PlanValidator.validate_plan("tok-broken")

    StubBackend.clear()
  end
end
