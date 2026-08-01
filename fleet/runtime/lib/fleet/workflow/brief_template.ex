defmodule Fleet.Workflow.BriefTemplate do
  @moduledoc """
  Loader of the brief-document templates (`priv/workflow/brief_templates/*.md`) — the
  engine side of F-23: the PROSE of the briefs (wording, tone, structure) is CALIBRATION
  DATA, editable by the human without compiling; the code only fills mechanical slots.

  **Token substitution WITHOUT evaluation** (`{{token}}` → value): a template is inert
  data — a poisoned template cannot execute anything. FAIL-LOUD both ways: a missing
  template file raises (`File.read!`), an unfilled token raises (`Map.fetch!` on the
  assigns), a leftover `{{…}}` after rendering raises (belt: a typoed token never ships
  silently inside an agent brief).

  Read on EVERY render (no cache, deliberate): brief composition is low-frequency and a
  calibration edit must take effect immediately — a cache would freeze the human's
  adjustment until reboot, the exact opposite of the surface's purpose.

  **Last revised**: 2026-08-01
  """

  @doc """
  Renders template `name` (`<catalogue>/workflow/brief_templates/<name>.md`) with `assigns`
  (string-keyed). Raises on: missing file, token absent from assigns, leftover braces.
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

  # The file's lineage header (`<!-- Date: … -->` leading comment, GO-7) is FILE metadata,
  # never brief content — stripped before render, same convention as the SP-block composer.
  defp strip_header(content),
    do: String.replace(content, ~r/\A(?:<!--.*?-->\n)+/s, "")
end
