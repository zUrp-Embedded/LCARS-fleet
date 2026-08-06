defmodule Fleet.EnvParse do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Domain-typed parsing of environment variables for `config/runtime.exs` — a PURE, TESTABLE primitive
  (foundation, alongside `Fleet.Slug`/`Fleet.GitRef`).

  `runtime.exs` is wrapped in `if config_env() != :test do … end`, so an inline lambda there can NEVER
  be unit-tested — and a parser that only checks the syntactic integer lets a negative/zero/out-of-range
  port through. Each function here parses the DOMAIN, and is testable.

  Doctrine: a LOAD-BEARING knob (port, interval) with an invalid value →
  `raise` a clear message = boot REFUSED (a typo must not boot a broken daemon, but with a readable error,
  not an opaque `String.to_integer` stacktrace). A boolean feature-flag typo → the documented default +
  a LOUD warning (a flag typo should be visible, but must not kill the boot).

  **Last revised**: 2026-08-03
  """

  require Logger

  @doc "TCP port (1..65535). Non-integer / out-of-range → raise (boot refused)."
  @spec port(String.t(), String.t()) :: pos_integer()
  def port(name, value), do: bounded_int(name, value, 1, 65_535, "a TCP port (1..65535)")

  @doc "Strictly-positive duration in ms (> 0). Non-integer / ≤ 0 → raise."
  @spec positive_ms(String.t(), String.t()) :: pos_integer()
  def positive_ms(name, value), do: bounded_int(name, value, 1, nil, "a positive duration in ms")

  @doc "Non-negative count (≥ 0). Non-integer / negative → raise."
  @spec count(String.t(), String.t()) :: non_neg_integer()
  def count(name, value), do: bounded_int(name, value, 0, nil, "a non-negative count")

  @doc """
  Integer inside an explicit `min..max`. Outside, or not an integer → raise = boot refused.

  For knobs whose bounds belong to a DOMAIN authority rather than to this module (a ceiling that
  some module owns and that this one must not restate). REFUSES rather than clamps: a clamped value
  boots green and runs at something the operator never typed, and the symptom of a wrong fan —
  tickets waiting — reads like a busy fleet, not like a misconfiguration.
  """
  @spec bounded(String.t(), String.t(), integer(), integer()) :: integer()
  def bounded(name, value, min, max) when is_integer(min) and is_integer(max),
    do: bounded_int(name, value, min, max, "an integer in #{min}..#{max}")

  defp bounded_int(name, value, min, max, expectation) when is_binary(value) do
    with {n, ""} <- Integer.parse(value),
         true <- n >= min,
         true <- is_nil(max) or n <= max do
      n
    else
      _ ->
        raise "LCARS config: #{name}=#{inspect(value)} is not #{expectation} — boot refused (fix the env)"
    end
  end

  @truthy ~w(true 1 yes on)
  @falsy ~w(false 0 no off)

  @doc """
  Parses `true/1/yes/on` and `false/0/no/off`, case-insensitively.

  Unset values return `default`; unknown values log a warning and return it.
  """
  @spec bool(String.t(), String.t() | nil, boolean()) :: boolean()
  def bool(_name, nil, default) when is_boolean(default), do: default

  def bool(name, value, default) when is_binary(value) and is_boolean(default) do
    case value |> String.trim() |> String.downcase() do
      v when v in @truthy ->
        true

      v when v in @falsy ->
        false

      _ ->
        Logger.warning(
          "LCARS config: #{name}=#{inspect(value)} is not a recognized boolean " <>
            "(true/1/yes/on | false/0/no/off) — using default #{default}"
        )

        default
    end
  end

  @doc """
  Strict boolean parser for safety flags.

  Unset values return `default`; unknown values raise instead of falling back.
  """
  @spec bool!(String.t(), String.t() | nil, boolean()) :: boolean()
  def bool!(_name, nil, default) when is_boolean(default), do: default

  def bool!(name, value, default) when is_binary(value) and is_boolean(default) do
    case value |> String.trim() |> String.downcase() do
      v when v in @truthy ->
        true

      v when v in @falsy ->
        false

      _ ->
        raise ArgumentError,
              "LCARS config: #{name}=#{inspect(value)} is not a recognized boolean " <>
                "(true/1/yes/on | false/0/no/off) — refusing to boot rather than fall " <>
                "back to the active default (#{default}) on a safety flag"
    end
  end

  @doc """
  Expands an operator-provided path. Control characters and `..` raise; no
  root policy is imposed.
  """
  @spec path(String.t(), String.t()) :: String.t()
  def path(name, value) when is_binary(value) do
    cond do
      String.match?(value, ~r/[\x00-\x1F\x7F]/) ->
        raise "LCARS config: #{name}=#{inspect(value)} contains a control char — boot refused (fix the env)"

      String.contains?(value, "..") ->
        raise "LCARS config: #{name}=#{inspect(value)} contains `..` (path traversal) — boot refused (fix the env)"

      true ->
        Path.expand(value)
    end
  end
end
