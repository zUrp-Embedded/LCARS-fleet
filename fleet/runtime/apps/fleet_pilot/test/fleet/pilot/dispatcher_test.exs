defmodule Fleet.Pilot.DispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Dispatcher

  defmodule StubForge do
    def add_label(_repo, _issue, _label, _opts) do
      Process.get(:stub_forge_response, {:ok, :added})
    end
  end

  defmodule StubInvoker do
    @behaviour Fleet.Pilot.PipelineInvoker

    @impl Fleet.Pilot.PipelineInvoker
    def start_pipeline(pipeline_name, mandate_context, _opts) do
      send(self(), {:invoked, pipeline_name, mandate_context})
      Process.get(:stub_invoker_response, {:ok, "stub-#{pipeline_name}"})
    end
  end

  defp config(overrides \\ %{}) do
    base = %{
      dispatch_label: "lcars-dispatched",
      forge_opts: [],
      forge_client: StubForge,
      invoker: StubInvoker
    }

    Map.merge(base, overrides)
  end

  defp payload(opts \\ []) do
    %{
      "issue" => %{
        "number" => opts[:number] || 42,
        "title" => opts[:title] || "Test",
        "body" => opts[:body] || "Brief",
        "html_url" => opts[:url] || "http://forge/x/y/issues/42"
      }
    }
  end

  describe "dispatch/5" do
    test "lock OK + invoke OK → {:dispatched, pipeline_id}" do
      assert {:dispatched, "stub-poc-cycle"} =
               Dispatcher.dispatch(config(), "poc-cycle", "fleet/lcars", 42, payload())

      assert_received {:invoked, "poc-cycle",
                       %{
                         ticket_id: "fleet/lcars#42",
                         ask: "Brief",
                         issue_title: "Test",
                         issue_url: "http://forge/x/y/issues/42"
                       }}
    end

    test "label déjà présent → {:skipped, :already_dispatched}, pas d'invoke" do
      Process.put(:stub_forge_response, {:ok, :already_present})

      assert {:skipped, :already_dispatched} =
               Dispatcher.dispatch(config(), "p", "fleet/lcars", 42, payload())

      refute_received {:invoked, _, _}
    end

    test "lock fail (HTTP error) → propagation {:error, ...}, pas d'invoke" do
      Process.put(:stub_forge_response, {:error, {:http, 500, "boom"}})

      assert {:error, {:http, 500, "boom"}} =
               Dispatcher.dispatch(config(), "p", "fleet/lcars", 42, payload())

      refute_received {:invoked, _, _}
    end

    test "invoke fail → propagation" do
      Process.put(:stub_invoker_response, {:error, :ticket_id_required})

      assert {:error, :ticket_id_required} =
               Dispatcher.dispatch(config(), "p", "fleet/lcars", 42, payload())
    end

    test "ask absent → string vide (pas crash)" do
      payload_no_body = %{"issue" => %{"number" => 42}}

      assert {:dispatched, _} =
               Dispatcher.dispatch(config(), "p", "fleet/lcars", 42, payload_no_body)

      assert_received {:invoked, "p", %{ask: ""}}
    end
  end
end
