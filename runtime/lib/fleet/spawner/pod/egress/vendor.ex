defmodule Fleet.Spawner.Pod.Egress.Vendor do
  @moduledoc """
  Reads vendor host declarations beside the actual launcher: `<vendor>_launch.egress`.
  Keeping endpoints with each launcher lets vendors declare their needs without changing
  the proxy. A missing/unreadable declaration logs an error and contributes no vendor hosts.
  """

  require Logger

  @doc """
  Reads hosts from the declaration derived from the launcher that will run,
  preventing a separate vendor-name setting from selecting another vendor’s list.
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
  Derives the adjacent `.egress` path from the launcher basename (replacing `.sh`).
  """
  @spec declaration_path(Path.t()) :: Path.t()
  def declaration_path(launcher_path) when is_binary(launcher_path) do
    dir = Path.dirname(launcher_path)
    base = launcher_path |> Path.basename() |> String.replace_suffix(".sh", "")
    Path.join(dir, base <> ".egress")
  end

  @doc """
  Parses one host per line, strips `#` comments and blanks, and deduplicates.
  Shared with the converged state-volume list; parsing does not grant access.
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
