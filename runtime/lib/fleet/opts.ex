defmodule Fleet.Opts do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Pure option-list helpers, shared across domains.

  Foundation because it is: two total functions over keyword lists, no dependency, no subject of
  its own. Held inside a domain, it would owe that domain an upward reference from every other
  caller.
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
end
