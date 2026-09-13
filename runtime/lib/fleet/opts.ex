defmodule Fleet.Opts do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Shared helpers for optional keyword values, tagged results and loaded-module export probes.
  """

  @doc """
  Puts a non-nil value and leaves the options unchanged for `nil`.
  """
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Tags an error with its resolution stage and passes successful results unchanged.
  """
  @spec tag_err({:ok, term()} | {:error, term()}, atom()) :: {:ok, term()} | {:error, term()}
  def tag_err({:ok, _} = ok, _tag), do: ok
  def tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

  @doc """
  Loads mod before checking fun/arity. function_exported?/3 alone returns false for unloaded
  modules, making available injected seams look unimplemented during lazy loading (e.g. mix run).
  """
  @spec exported?(module(), atom(), non_neg_integer()) :: boolean()
  def exported?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
