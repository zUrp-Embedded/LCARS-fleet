defmodule Fleet.Forge.Client.UrlSafe do
  @moduledoc """
  Encodes forge path segments without changing their structural separators.

  Atomic segments encode embedded separators and query/fragment characters. Repository and file
  paths preserve `/` between components while neutralizing literal `.` and `..`, which ordinary URI
  form encoding leaves untouched.
  """

  @doc "Encodes an atomic URL component (renders `/`, `..`, space, `?`, `#` inert)."
  @spec encode_seg(String.t()) :: String.t()
  def encode_seg(seg) when is_binary(seg), do: encode_component(seg)

  @doc """
  Encodes an `owner/name`, preserving structural separators and neutralizing traversal components.
  """
  @spec encode_repo(String.t()) :: String.t()
  def encode_repo(repo) when is_binary(repo) do
    repo |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  @doc """
  Encodes a multi-segment file path while preserving structural separators.
  """
  @spec encode_path(String.t()) :: String.t()
  def encode_path(path) when is_binary(path) do
    path |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  # URI form encoding leaves traversal dots intact and represents path spaces as `+`.
  defp encode_component(comp) when comp in [".", ".."] do
    String.replace(comp, ".", "%2E")
  end

  defp encode_component(comp) when is_binary(comp) do
    comp |> URI.encode_www_form() |> String.replace("+", "%20")
  end
end
