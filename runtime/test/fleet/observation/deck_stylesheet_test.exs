defmodule Fleet.Observation.DeckStylesheetTest do
  @moduledoc """
  The deck stylesheet DESCRIBES a DOM. Nothing else confronts it with the DOM the view emits.

  A class selector is prose in the imperative mood: `.lcars-rail { … }` states that a rail exists.
  When the view never emits it the rule reads as live intent for every session after — and it can
  ACT. Measured live (2026-08-02): `.lcars-frame` reserved a 110px track for `.lcars-rail`, a class
  `view.ex` never renders. The track did not stay empty; the first auto-placed child
  (`.lcars-main`) landed IN it and stacked the seven panels in a column while three quarters of the
  screen sat black. The gate could not see it: it measures code, and this was a disagreement
  between two descriptions.

  THE ANCHOR IS AN INVENTORY, DELIBERATELY. A first attempt asserted that no ghost class may carry
  a placement declaration; it flagged rules that are inert (they need a ghost ancestor state to
  apply at all) and it would have MISSED the one that bit — the harmful rule belonged to a REAL
  class reserving a track for an absent child. A guard that misses its own motivating case is worse
  than none. What does catch it, upstream and cheaply: `.lcars-rail` was styled and never emitted,
  so the ghost count would have risen the day it was written.

  The count is high today (a stylesheet written for a DOM this repo never rendered). Purging is
  render-neutral by construction — a selector that matches nothing does nothing — but it would
  erase design intent that lives nowhere else, so it is its own pass, not a side effect of this one.
  """
  use ExUnit.Case, async: true

  @view_path "lib/fleet/observation/deck/view.ex"
  @css_path "priv/observation/static/lcars-tva.css"

  # Selectors whose element is posed by the browser or an extension, never by the view. Each entry
  # states why: an unexplained one is how a dead rule comes back through the door.
  @not_emitted_by_the_view MapSet.new([
                             # decorative overlay injected client-side, no server markup
                             "crt-overlay"
                           ])

  # Measured 2026-08-02. May only go DOWN — a wall, not a target.
  @known_ghosts 118

  defp read!(rel), do: File.read!(Path.join(File.cwd!(), rel))

  defp ghosts(css, view) do
    css
    |> String.replace(~r|/\*.*?\*/|s, " ")
    |> then(&Regex.scan(~r/\.(-?[_a-zA-Z][\w-]*)/, &1))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    # The view holds BOTH the markup and the JS that builds the live rows: a name present anywhere
    # in that file reaches a browser at some point. Absent from it, it reaches one never.
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
