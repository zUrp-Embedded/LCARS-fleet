defmodule Fleet.Grace do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The two-tick grace, as ONE pure function.

  A periodic reconciliation compares two views of the same population — sockets on disk against
  live pods, locks on the forge against working pods, acceptors against socket files — and acts on
  the difference. Every such difference has a legitimate transient: a pod being born already owns
  its socket and no Registry entry yet; a pod being torn down still has its acceptor and no pod;
  a freshly dispatched brick carries its lock before its pod registers. Acting on the first
  observation would kill what is merely in transition.

  So a candidate is acted upon only when it was ALREADY a suspect at the previous tick:

      {to_act, new_suspects} = Fleet.Grace.two_tick(candidates_now, prior_suspects)

  `to_act` is what to reap, reclaim or report; `new_suspects` is what the caller carries to its
  next tick — the candidates seen now that were not confirmed. A candidate absent from
  `candidates_now` drops out of both sets: a transient that resolved itself owes nothing.

  The reconcilers that call this (grep for them) each carried the same three lines as a private
  copy. One copy lives here so the grace has ONE definition to read, and so the next reconciler
  does not write another.

  ⚠ The grace unit is the CALLER's regular tick, and only that. A caller with an out-of-band
  trigger (a webhook kick, a `:check_now`) must NOT thread this function through it, or the grace
  compresses to the trigger rate — the poller documents that exact trap for its webhook kicks.

  What is NOT here: what to do with a FAILED action. The poller keeps a failed reclaim as a
  suspect (`MapSet.union(new_suspects, failed)`) so the retry is the next tick rather than a fresh
  two-tick re-suspicion; the wardens let a failed reap re-suspect itself. Both are the caller's
  policy on top of this function, not variants of it.
  """

  @doc """
  Splits the candidates of THIS tick into those confirmed by the previous tick and those to carry.

  Pure: no process, no clock. The two returned sets are disjoint and their union is `candidates`.
  """
  @spec two_tick(MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  def two_tick(%MapSet{} = candidates, %MapSet{} = prior_suspects) do
    to_act = MapSet.intersection(candidates, prior_suspects)
    {to_act, MapSet.difference(candidates, to_act)}
  end
end
