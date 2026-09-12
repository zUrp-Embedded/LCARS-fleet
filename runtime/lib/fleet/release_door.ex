defmodule Fleet.ReleaseDoor do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Keeps the default logger off stdout for release-eval functions consumed by shell parsers.
  Catalogue/project verdicts are protocol data: a successful operation can appear failed if log
  lines contaminate that stream. Diagnostics move to stderr instead of being disabled.
  """

  @doc """
  Recreates the node-global default handler on stderr, retaining its other settings.
  Call first, before anything can log. logger_std_h's type cannot be updated on a live handler,
  hence remove/add. Failures raise: a door must not continue with mixed protocol output.
  Other handlers and direct stdout writes are unaffected.
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
