defmodule Fleet.Observation.DeckStylesheetTest do
  @moduledoc """
  Caps a textual inventory of CSS class names absent from the entire view source.
  Regression: a real lcars-frame rule reserved a 110px track for absent lcars-rail;
  auto-placement put the main panel in that track. Checking only unused selectors'
  placement declarations would miss this effect on a real parent.

  This is a substring heuristic, not DOM/CSS execution: comments can satisfy a match,
  and dynamic construction can evade it. CSS cleanup requires its own rendering review.
  """
  use ExUnit.Case, async: true

  @view_path "lib/fleet/observation/deck/view.ex"
  @css_path "priv/observation/static/lcars-tva.css"

  # Explicit exemption retained by the inventory; crt-overlay is also present in page markup.
  @not_emitted_by_the_view MapSet.new([
                             "crt-overlay"
                           ])

  # Baseline ceiling measured 2026-08-02; lower it when the inventory shrinks.
  @known_ghosts 118

  defp read!(rel), do: File.read!(Path.join(File.cwd!(), rel))

  defp ghosts(css, view) do
    css
    |> String.replace(~r|/\*.*?\*/|s, " ")
    |> then(&Regex.scan(~r/\.(-?[_a-zA-Z][\w-]*)/, &1))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    # Search the whole source, including JS and comments; a match does not prove emission.
    |> Enum.reject(&(MapSet.member?(@not_emitted_by_the_view, &1) or String.contains?(view, &1)))
    |> Enum.sort()
  end

  test "the inventory of classes styled but never emitted may only shrink" do
    dead = ghosts(read!(@css_path), read!(@view_path))

    assert length(dead) <= @known_ghosts,
           """
           La feuille style #{length(dead)} classes que la vue n'emet jamais (plancher : #{@known_ghosts}).
           Une regle qui ne matche rien ne rend rien — mais elle se lit comme une intention vivante,
           et elle peut agir : une piste reservee a une classe absente est prise par le premier
           enfant auto-place. Retirer la regle, ou emettre l'element : jamais les deux moities
           d'une decision qu'on n'a pas prise.

           Echantillon : #{inspect(Enum.take(dead, 12))}
           """

    if length(dead) < @known_ghosts do
      IO.puts(
        "\n[deck stylesheet] #{@known_ghosts - length(dead)} fantome(s) de moins — " <>
          "baisser @known_ghosts a #{length(dead)}.\n"
      )
    end
  end
end
