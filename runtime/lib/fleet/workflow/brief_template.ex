defmodule Fleet.Workflow.BriefTemplate do
  @moduledoc """
  F-23 template loader: inert token substitution for human-editable calibration prose.
  Reads templates on every render, strips leading HTML-comment headers and substitutes {{word}}
  tokens once. Missing assigns and remaining matching tokens raise; other brace syntax is untouched.
  """

  @doc """
  Renders catalogue brief_templates_root/name.md with string-keyed assigns, without evaluating them.
  Name is joined as supplied, without confinement validation; extra assigns are ignored.
  """
  @spec render(String.t(), %{String.t() => String.t()}) :: String.t()
  def render(name, assigns) when is_binary(name) and is_map(assigns) do
    rendered =
      priv_path(name)
      |> File.read!()
      |> strip_header()
      |> then(
        &Regex.replace(~r/\{\{(\w+)\}\}/, &1, fn _, token -> Map.fetch!(assigns, token) end)
      )

    if rendered =~ ~r/\{\{\w+\}\}/ do
      raise ArgumentError,
            "brief template #{name}: unresolved token after render — calibration error, refusing to ship"
    end

    rendered
  end

  defp priv_path(name),
    do: Path.join(Fleet.Catalogue.brief_templates_root(), name <> ".md")

  # GO-7 lineage header is file metadata, not rendered content.
  defp strip_header(content),
    do: String.replace(content, ~r/\A(?:<!--.*?-->\n)+/s, "")
end
