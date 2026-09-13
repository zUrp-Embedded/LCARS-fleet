defmodule Fleet.Pilot.Offload do
  @moduledoc """
  Runs work under a Task.Supervisor and tracks task monitors in the calling
  process's dictionary. Consumers must route DOWN messages back to handle_down/3
  in that same process. Admission success is not a work-completion receipt.
  """

  require Logger

  @doc """
  Starts fun under supervisor_name, then monitors it. A returned admission error
  is logged and wrapped as {:error, {:offload_failed, reason}}; exceptions/exits
  from starting the task propagate.

  Labels are {consumer, consequence} or {consumer, consequence, metadata_map}.
  Abnormal task death returns metadata through handle_down/3 for caller recovery.
  {:ok, :offloaded} reports admission, not the function's result.
  """
  @spec async(
          atom(),
          (-> any()),
          {String.t(), String.t()} | {String.t(), String.t(), map()}
        ) ::
          {:ok, :offloaded} | {:error, {:offload_failed, term()}}
  def async(supervisor_name, fun, label) do
    {consumer, consequence} = consumer_consequence(label)

    case start_monitored(supervisor_name, fun, label) do
      {:ok, :offloaded} = ok ->
        ok

      {:error, reason} ->
        Logger.error("#{consumer}: offload Task failed (#{inspect(reason)}) — #{consequence}")

        {:error, {:offload_failed, reason}}
    end
  end

  defp consumer_consequence({consumer, consequence}), do: {consumer, consequence}
  defp consumer_consequence({consumer, consequence, _meta}), do: {consumer, consequence}

  defp label_meta({_consumer, _consequence}), do: %{}
  defp label_meta({_consumer, _consequence, meta}) when is_map(meta), do: meta

  # Monitor in the caller so its mailbox receives DOWN. Store context by monitor
  # reference until handle_down removes it; dropping DOWN messages leaks entries.
  # A task can exit before the monitor attaches, yielding :noproc.
  defp start_monitored(supervisor_name, fun, label) do
    case Task.Supervisor.start_child(supervisor_name, fun) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Process.put({__MODULE__, ref}, label)
        {:ok, :offloaded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Falls back to running fun in the caller when task admission returns an error
  such as :max_children. Exceptions, throws and exits from the inline function
  are logged and returned as {:error, :inline_crashed}; its normal return is ignored.

  No deadline is imposed here. Admission itself is outside the rescue/catch, so
  a missing supervisor can exit instead of falling back. Consumers share this
  policy to avoid dropping work on pool saturation.
  """
  @spec async_or_inline(
          atom(),
          (-> any()),
          {String.t(), String.t()} | {String.t(), String.t(), map()}
        ) ::
          {:ok, :offloaded} | {:ok, :inline} | {:error, :inline_crashed}
  def async_or_inline(supervisor_name, fun, label) do
    {consumer, consequence} = consumer_consequence(label)

    case start_monitored(supervisor_name, fun, label) do
      {:ok, :offloaded} = ok ->
        ok

      {:error, reason} ->
        # Report refused admission and the inline fallback together.
        Logger.warning(
          "#{consumer}: offload refused (#{inspect(reason)}) → falls back to INLINE " <>
            "(bounded; #{consequence} avoided)"
        )

        try do
          fun.()
          {:ok, :inline}
        rescue
          e ->
            Logger.error(
              "#{consumer}: INLINE fallback crashed (#{Exception.message(e)}) — #{consequence}"
            )

            {:error, :inline_crashed}
        catch
          kind, reason ->
            Logger.error(
              "#{consumer}: INLINE fallback crashed (#{kind} #{inspect(reason)}) — #{consequence}"
            )

            {:error, :inline_crashed}
        end
    end
  end

  @doc """
  Consumes this caller's monitor entry. Unknown or already-consumed refs return
  :not_mine. :normal, :shutdown and {:shutdown, _} return {:handled, :nominal}
  silently; this classification does not prove the work completed.

  Other reasons log and return {:handled, {:died, reason, metadata}}. A two-field
  label supplies an empty map. :noproc is treated as failure conservatively,
  because a task exiting before monitoring loses its actual exit reason.
  """
  @spec handle_down(reference(), pid(), term()) ::
          :not_mine | {:handled, :nominal} | {:handled, {:died, term(), map()}}
  def handle_down(ref, _pid, reason) do
    case Process.delete({__MODULE__, ref}) do
      nil ->
        :not_mine

      label ->
        {consumer, consequence} = consumer_consequence(label)

        case reason do
          :normal ->
            {:handled, :nominal}

          :shutdown ->
            {:handled, :nominal}

          {:shutdown, _} ->
            {:handled, :nominal}

          # A pre-monitor exit loses its actual reason, including normal completion.
          # Report conservatively rather than silently losing a possible failure.
          :noproc ->
            Logger.error(
              "#{consumer}: offloaded task DIED mid-work (:noproc — exited before monitor) — #{consequence}"
            )

            {:handled, {:died, :noproc, label_meta(label)}}

          other ->
            Logger.error(
              "#{consumer}: offloaded task DIED mid-work (#{inspect(other)}) — #{consequence}"
            )

            {:handled, {:died, other, label_meta(label)}}
        end
    end
  end
end
