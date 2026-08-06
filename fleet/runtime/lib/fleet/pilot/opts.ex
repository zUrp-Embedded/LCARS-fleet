defmodule Fleet.Pilot.Opts do
  @moduledoc """
  Pure helpers for building option keyword-lists (injectable opts/seams).

  SINGLE source of the "set the key IF the value is not nil" idiom — used by
  the pilot's opts builders (`StepRunConsumer`, `ForgeClient.Transport`, `Poller`,
  and the spawn_opts builders of `StepDispatcher`/`ReviewLifecycle`: `:project`,
  `:repo_id`) to inject an optional seam/parameter only when it is actually
  present. (A coupled MULTI-key set — e.g. `Spawn.maybe_put_route/2`, 2 keys —
  is not this idiom and stays with its authority.)
  """

  @doc """
  Sets `{key, value}` in `opts` IF `value != nil`; otherwise returns `opts` unchanged
  (the default value swallows the absence). Preserves the existing order (`Keyword.put`).
  """
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Tags a resolution error with its stage (`{:error, reason}` → `{:error, {tag, reason}}`,
  `{:ok, _}` passes unchanged). Shared by BOTH dispatcher flows (issue + review) — both
  take it from this same source; the core→ReviewLifecycle uni-directionality holds
  without a fn capture in the Ctx.
  """
  @spec tag_err({:ok, term()} | {:error, term()}, atom()) :: {:ok, term()} | {:error, term()}
  def tag_err({:ok, _} = ok, _tag), do: ok
  def tag_err({:error, reason}, tag), do: {:error, {tag, reason}}
end
