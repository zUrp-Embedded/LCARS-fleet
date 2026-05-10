defmodule Fleet.CapProfile.Loader do
  @moduledoc """
  Behaviour for the Capability Profile loader/composer/validator.

  Exposed to allow mock implementations in tests and a future second
  vendor (alternate schema or transport). The default implementation is
  `Fleet.CapProfile`.
  """

  @callback load(role :: String.t()) ::
              {:ok, Fleet.CapProfile.t()} | {:error, atom() | String.t()}

  @callback compose(role :: String.t(), modop_set :: [String.t()]) ::
              {:ok, Fleet.CapProfile.t()} | {:error, term()}

  @callback validate(profile :: Fleet.CapProfile.t()) ::
              :ok | {:error, [violation :: atom()]}
end
