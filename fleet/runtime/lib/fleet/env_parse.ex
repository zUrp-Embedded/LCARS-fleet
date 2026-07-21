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

  **Last revised**: 2026-07-21
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
  Boolean env value. Recognizes `true/1/yes/on` and `false/0/no/off` (case-insensitive, trimmed). `nil`
  (unset) → `default`. An UNRECOGNIZED value → `default` + a LOUD warning (a typo like `flase`
  must not silently become the default — it is logged).
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
  Strict variant of `bool/3` for flags whose WRONG reading is dangerous in one direction
  (a maintenance / reduction-of-effects switch): unset → `default`, recognized → its
  value, UNRECOGNIZED → raise (the boot refuses). `bool/3` warns-and-defaults, which is
  fail-open exactly when the operator asked for fewer effects — a typo there must stop
  the boot, never silently become the active default. Adopt per-flag, deliberately:
  strictness on an ordinary tuning knob would trade a boot for a cosmetic typo.
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
  Normalize an operator-provided path: `Path.expand` (resolves `~`/relative → absolute). A NUL/control
  char, or a `..` traversal → raise = boot refused. NO root-policy: the operator sets these
  paths intentionally; only the manifestly-broken is refused.
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
