defmodule Fleet.Workflow.GateDecision do
  @moduledoc """
  Canonical gatekeeper decision vocabulary, shared by rendering and validation.
  The wire schema mirror is regression-tested; internal `halt_invalid` is excluded.
  """

  @decisions ~w(continue abandon redirect escalate_user halt_wait_input)

  @doc "Canonical valid decisions in brief-rendering order."
  @spec decisions() :: [String.t()]
  def decisions, do: @decisions
end
