defmodule Fleet.GitRef do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Shared validation of git ref names.

  The validator rejects malformed names before they reach git while callers
  retain their own error shapes. It validates refs, not creatable branch names:
  `HEAD` is deliberately valid for the local side of a push.
  """

  @ref_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/\-]*\z/

  @doc """
  Returns whether `ref` follows the supported git ref grammar.

  Components are non-empty, cannot start with `.`, end with `.lock`, or
  contain `..`; the whole ref must match the restricted ASCII charset.
  """
  @spec valid?(term()) :: boolean()
  def valid?(ref) when is_binary(ref) do
    Regex.match?(@ref_re, ref) and
      not String.contains?(ref, "..") and
      not String.ends_with?(ref, ".") and
      valid_components?(ref)
  end

  def valid?(_), do: false

  defp valid_components?(ref) do
    ref
    |> String.split("/")
    |> Enum.all?(fn comp ->
      comp != "" and
        not String.starts_with?(comp, ".") and
        not String.ends_with?(comp, ".lock")
    end)
  end
end
