defmodule Fleet.Starfleet.BootOrchestrator do
  @moduledoc """
  One-shot permanent-pod orchestration invoked after root readiness. It optionally
  runs `Fleet.Spawner.PermanentBoot`, then logs and broadcasts exactly one
  `fleet.boot_complete`, `fleet.boot_partial`, or `fleet.boot_failed` outcome.

  Exceptions, exits, and throws become a failed outcome; `run/1` always returns
  `:ok`, which means the orchestration finished, not that every pod started. Event
  delivery is observability-only and may be unavailable early in boot; the spawner
  registry is the durable state, and `PermanentWarden` owns later recovery.
  """

  require Logger
  alias Fleet.EventRouter.Bus

  @doc """
  Runs one orchestration with injectable boot seams. Returns `:ok` after recording
  any complete, partial, or failed outcome.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    boot_fn =
      Keyword.get(opts, :boot_permanent_pods, fn ->
        Fleet.Spawner.PermanentBoot.boot_permanent_pods()
      end)

    enabled? =
      Keyword.get(opts, :boot_permanent_enabled, Fleet.Spawner.PermanentBoot.auto_boot_enabled?())

    started_apps =
      Application.started_applications()
      |> Enum.map(fn {a, _, _} -> a end)
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "lcars"))
      |> Enum.sort()

    Logger.info("BootOrchestrator: starting post-readiness sequence (boot_permanent=#{enabled?})")

    boot_result = if enabled?, do: safe_boot(boot_fn), else: {:ok, []}

    _ =
      case boot_result do
        {:ok, pods} ->
          emit_complete(started_apps, pods)

        {:partial, pods, failed} ->
          emit_partial(started_apps, pods, failed)

        {:failed, reason} ->
          emit_failed(reason)
      end

    :ok
  end

  defp safe_boot(boot_fn) do
    case boot_fn.() do
      results when is_list(results) ->
        {oks, errs} =
          Enum.split_with(results, fn
            {:ok, _} -> true
            {:error, _} -> false
            _ -> false
          end)

        case errs do
          [] -> {:ok, oks}
          _ -> {:partial, oks, errs}
        end

      {:error, reason} ->
        {:failed, reason}

      other ->
        {:failed, {:unexpected_return, other}}
    end
  rescue
    e -> {:failed, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:failed, {:caught, kind, reason}}
  end

  defp emit_complete(apps, pods) do
    payload = %{
      "started_apps" => Enum.map(apps, &Atom.to_string/1),
      "permanent_pods" => length(pods)
    }

    Logger.info("BootOrchestrator: fleet.boot_complete pods=#{length(pods)}")
    emit_canon(:"fleet.boot_complete", payload)
  end

  defp emit_partial(apps, pods, failed) do
    payload = %{
      "started_apps" => Enum.map(apps, &Atom.to_string/1),
      "permanent_pods" => length(pods),
      "failed_pods" => Enum.map(failed, &inspect/1)
    }

    Logger.warning(
      "BootOrchestrator: fleet.boot_partial pods=#{length(pods)} failed=#{length(failed)}"
    )

    emit_canon(:"fleet.boot_partial", payload)
  end

  defp emit_failed(reason) do
    payload = %{"reason" => inspect(reason)}
    Logger.error("BootOrchestrator: fleet.boot_failed reason=#{inspect(reason)}")
    emit_canon(:"fleet.boot_failed", payload)
  end

  defp emit_canon(type, payload) do
    Bus.safe_emit(:starfleet, type, [payload: payload],
      on_unregistered: :silent,
      context: "BootOrchestrator: lifecycle event NOT emitted"
    )
  end
end
