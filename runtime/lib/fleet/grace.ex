defmodule Fleet.Grace do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Two-observation grace for reconcilers. Sockets, Registry entries and forge locks can briefly
  disagree during pod startup/teardown; acting immediately would reclaim resources still in use.

      {to_act, new_suspects} = Fleet.Grace.two_tick(candidates_now, prior_suspects)

  Candidates already suspected become to_act; fresh candidates become new_suspects, which the
  caller carries forward. Disappeared candidates drop out of both sets.

  Advance this state only on regular ticks: webhook/check-now triggers would compress the grace
  to their arrival rate. Failed-action policy belongs to callers: the poller retains failures for
  next-tick retry, while wardens can require a fresh two-tick suspicion.
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
