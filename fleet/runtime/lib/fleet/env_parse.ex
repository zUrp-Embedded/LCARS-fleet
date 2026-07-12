defmodule Fleet.EnvParse do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary, deps: [], exports: []

  @moduledoc """
  Domain-typed parsing of environment variables for `config/runtime.exs` — a PURE, TESTABLE primitive
  (Ring 0, alongside `Fleet.Slug`/`Fleet.GitRef`).

  `runtime.exs` is wrapped in `if config_env() != :test do … end`, so an inline lambda there can NEVER be
  unit-tested — the root of SOC-CONF-001/002/003 (a `parse_int` that checked the syntactic integer but not
  the DOMAIN: a negative/zero/out-of-range port passed). Each function here parses the DOMAIN.

  Doctrine (matches the old `parse_int`): a LOAD-BEARING knob (port, interval) with an invalid value →
  `raise` a clear message = boot REFUSED (a typo must not boot a broken daemon, but with a readable error,
  not an opaque `String.to_integer` stacktrace). A boolean feature-flag typo → the documented default +
  a LOUD warning (a flag typo should be visible, but must not kill the boot).
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
  (unset) → `default`. An UNRECOGNIZED value → `default` + a LOUD warning (SOC-CONF-002: a typo like
  `flase` must not silently become the default — it is logged).
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
  Normalize an operator-provided path: `Path.expand` (resolves `~`/relative → absolute). A NUL/control
  char, or a `..` traversal → raise = boot refused (SOC-CONF-003). NO root-policy: the operator sets these
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
