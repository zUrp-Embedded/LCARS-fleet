defmodule Fleet.Spawner.Pod.Egress.Vendor do
  @moduledoc """
  WHICH HOSTS A VENDOR NEEDS, declared once, beside the launcher that needs them.

  The N1 frontier is `bin/<vendor>_launch.sh` — one launcher per vendor, same argument shape. The
  hosts a vendor talks to are a property OF that vendor, so they live next to it:
  `bin/<vendor>_launch.egress`, one hostname per line, `#` comments allowed.

  That placement is the whole point, and it is asserted by a test rather than trusted: an endpoint
  is written in exactly ONE file of this repository, its vendor's declaration. The day a second
  vendor arrives it brings its own launcher AND its own declaration — nobody edits a list buried in
  the runtime to let a new model reach its API. A hardcoded endpoint in the middle of the spawner
  would make "add a vendor" an edit to the pod's projection itself, instead of a file laid beside
  the others.

  MISSING FILE = NO HOSTS, and the pod reaches nothing. Fail-closed on purpose: a vendor whose
  declaration is absent is a wiring hole, and a wiring hole that silently grants full egress is the
  failure this whole rail exists to prevent. It fails LOUD in the log and CLOSED in effect.
  """

  require Logger

  @doc """
  The hosts declared by `vendor`, read from `<launcher_dir>/<vendor>_launch.egress`.

  `launcher_path` is the vendor launcher the pod will actually exec — the declaration is resolved
  from IT rather than from a configured directory, so the two can never name different vendors.
  """
  @spec hosts(Path.t()) :: [String.t()]
  def hosts(launcher_path) when is_binary(launcher_path) do
    decl = declaration_path(launcher_path)

    case File.read(decl) do
      {:ok, body} ->
        parse(body)

      {:error, reason} ->
        Logger.error(
          "Egress.Vendor: no endpoint declaration at #{decl} (#{inspect(reason)}) — the pod " <>
            "reaches NOTHING. A vendor launcher without its `.egress` file is a wiring hole."
        )

        []
    end
  end

  @doc """
  The declaration path for a launcher: `bin/claude_launch.sh` → `bin/claude_launch.egress`.

  Derived from the launcher path, never composed from a vendor NAME held elsewhere: two ways to
  name the same vendor is how a pod ends up launched by one and authorized for another.
  """
  @spec declaration_path(Path.t()) :: Path.t()
  def declaration_path(launcher_path) when is_binary(launcher_path) do
    dir = Path.dirname(launcher_path)
    base = launcher_path |> Path.basename() |> String.replace_suffix(".sh", "")
    Path.join(dir, base <> ".egress")
  end

  @doc """
  Parses a host declaration: one hostname per line, `#` starts a comment, blanks dropped, deduped.

  PUBLIC BECAUSE A SECOND SOURCE SHARES THIS GRAMMAR — the converged allowlist that
  `Fleet.Spawner.Pod.Egress` reads off the state volume is the same file format, written by the
  toolchain converger instead of shipped beside a launcher. Two parsers for one format is two
  places to disagree about what a comment is, and the disagreement would show up as a host that
  is allowed on one path and refused on the other.

  It parses a FORMAT; it grants nothing. The decision stays in `Egress.decide/2`.
  """
  @spec parse(binary()) :: [String.t()]
  def parse(body) do
    body
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.split("#") |> List.first() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
