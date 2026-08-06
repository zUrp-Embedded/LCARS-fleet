defmodule Fleet.Pilot.Opts do
  @moduledoc """
  Pure option-list helpers shared by Pilot flows.
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
