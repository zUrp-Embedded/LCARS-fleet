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

  @doc """
  Does `mod` export `fun/arity` — LOADING it first. `function_exported?/3` answers `false` for a
  module that is merely not loaded yet, which outside a release (interactive mode: `mix run`,
  the bench) is every seam module before its first call — a live pipe read as a pod without
  `pod_info/1`, a pool without `has_free_slot?/3`, a queue without `list_active/0`. A release
  preloads its modules; a probe on an injected seam must not depend on it.
  """
  @spec exported?(module(), atom(), non_neg_integer()) :: boolean()
  def exported?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
end
