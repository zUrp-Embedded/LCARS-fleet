defmodule Fleet.ReleaseDoor do
  use Boundary, deps: [], exports: []

  @moduledoc """
  A release door's `stdout` is a PROTOCOL, and it is not shared with the logger.

  A release door is a function reached by `bin/lcars_fleet eval '…'`: it prints, it halts with a
  verdict, and something on the shell side READS what it printed — `bin/lcars` parses catalogue
  states word by word, `fleet/services/human.d/75-projects.sh` parses one verdict per project. That makes
  the door's output a wire format, not a console.

  ⚠ THE DEFAULT ERLANG LOG HANDLER WRITES TO THAT SAME `stdout`, and a door which does nothing
  about it is not "usually fine" — it is correct only while the code under it happens to stay
  quiet. The shape it takes: a door SUCCEEDS — the work is done, the state is right — and its
  CALLER reports failure, because the code under it logged one `info` and four `warning` and every
  one of those lines reached the parser as an unreadable verdict. The contract "one word per line"
  is then unachievable BY CONSTRUCTION, not broken by drift.

  Nothing is silenced. The diagnostics move to `stderr`, which is where a caller that separates the
  two streams already looks for them, and where a human reading the door still sees them.
  """

  @doc """
  Moves the default log handler to `stderr` so this process's `stdout` carries only the door's own
  lines. Call it FIRST in a door, before anything that can log.

  ⚠ REMOVE THEN ADD, and that is not a matter of style: `type` is immutable on a live handler —
  `:logger.update_handler_config/3` answers
  `{:error, {:illegal_config_change, :logger_std_h, %{type: :standard_io}, …}}`. The handler is
  recreated identical except for `type`, so the format and the level stay the ones the operator
  configured.

  NO FALLBACK. A door that cannot separate its streams must not print at all: a shared `stdout`
  produces lines the caller will read as data. It raises, the caller reports the crash.
  """
  @spec claim_stdout!() :: :ok
  def claim_stdout! do
    {:ok, cfg} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        cfg.module,
        %{cfg | config: Map.put(cfg.config, :type, :standard_error)}
      )
  end
end
