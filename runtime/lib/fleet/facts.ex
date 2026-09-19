defmodule Fleet.Facts do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Machine facts, read from `etc/facts.env` — the SAME file the shell, the Python and the installer read.

  A fact is something that is true of the machine before anyone installs anything: the `fleet`
  group, the system org, the token directory. It is written ONCE, in `etc/facts.env`, and this
  module is the Elixir side's only reader. What DERIVES from a fact (the org's `_ops` repository,
  the system account's token file) is derived by its reader, and stays a rule, not a fact.

  ## The environment wins over the file

  A fact is a DEFAULT. What provisioning carries in `/etc/lcars/services.env`, or what an operator
  sets by hand, takes precedence. The order is the shell's and the Python's, or the two rails would
  read two values under one name.

  ## An unreadable facts file REFUSES

  `get!/1` raises rather than returning an empty string. A daemon running with an empty token
  directory would write to the filesystem root: the worst failure mode, silent and destructive.
  Same doctrine as `Fleet.BootGuard` — what could not be read is not guessed.

  ## Where the file is

  Three candidates, in order: `LCARS_FACTS_FILE` (witnesses and operators), `etc/facts.env` under
  the current directory (a checkout, where Mix runs from `runtime/`), then `/opt/lcars/etc/facts.env`
  (an installed machine, where the release lives beside the posed product tree). The checkout comes
  first so a developer on a bench reads the tree under edit, not the one installed beside it.

  Readers are injectable so the witnesses drive every branch without touching the machine.
  """

  @machine_file "/opt/lcars/etc/facts.env"
  @checkout_file "etc/facts.env"

  @typedoc "Facts by name, as read from one file."
  @type t :: %{optional(String.t()) => String.t()}

  @doc """
  The facts file this machine would read, or `nil` if no candidate is readable.

  `:candidates` replaces the whole list; `:env` replaces the environment reader.
  """
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []) do
    opts
    |> candidates()
    |> Enum.find(&File.regular?/1)
  end

  @doc """
  The value of `key`: the environment first, the facts file second.

  Raises when neither carries it — a service does not run on a fact it does not have.
  """
  @spec get!(String.t(), keyword()) :: String.t()
  def get!(key, opts \\ []) when is_binary(key) do
    case get(key, nil, opts) do
      nil -> raise ArgumentError, unknown_message(key, opts)
      value -> value
    end
  end

  @doc """
  The value of `key`, or `default` when neither the environment nor the facts file carries it.

  An unreadable facts file still raises: `default` covers a missing KEY, never a missing FILE.
  """
  @spec get(String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def get(key, default, opts \\ []) when is_binary(key) do
    case env_get(key, opts) do
      value when is_binary(value) and value != "" -> value
      _ -> Map.get(load!(opts), key, default)
    end
  end

  @doc """
  Every fact of the file, as a map. Raises when no candidate is readable.
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    case path(opts) do
      nil -> raise File.Error, reason: :enoent, action: "read facts", path: unreadable(opts)
      file -> file |> File.read!() |> parse()
    end
  end

  @doc """
  Parses the facts format: `KEY=value` per line, no expansion, `#` comments and blanks ignored.

  A line without `=` is not a fact and is skipped; the format is data, deliberately not shell.
  """
  @spec parse(String.t()) :: t()
  def parse(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> [{String.trim(key), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp candidates(opts) do
    case Keyword.get(opts, :candidates) do
      nil ->
        named = env_get("LCARS_FACTS_FILE", opts)
        declared = if is_binary(named) and named != "", do: [named], else: []
        declared ++ [@checkout_file, @machine_file]

      list ->
        list
    end
  end

  defp env_get(name, opts) do
    Keyword.get(opts, :env, &System.get_env/1).(name)
  end

  defp unreadable(opts), do: opts |> candidates() |> Enum.join(", ")

  defp unknown_message(key, opts) do
    "unknown machine fact: #{key} (neither in the environment nor in " <>
      "#{path(opts) || unreadable(opts)}) — a fact is declared in etc/facts.env, never guessed here"
  end
end
