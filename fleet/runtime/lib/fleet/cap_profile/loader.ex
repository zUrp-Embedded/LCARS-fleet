defmodule Fleet.CapProfile.Loader do
  @moduledoc """
  Behaviour implemented by capability-profile loaders, composers, and validators.

  `Fleet.CapProfile` is the default implementation.
  """

  @callback load(role :: String.t()) ::
              {:ok, Fleet.CapProfile.t()} | {:error, atom() | String.t()}

  @callback compose(base :: Fleet.CapProfile.t() | String.t(), modop_set :: [String.t()]) ::
              {:ok, Fleet.CapProfile.t()} | {:error, term()}

  @callback validate(profile :: Fleet.CapProfile.t()) ::
              :ok | {:error, [violation :: atom()]}
end
