defmodule Fleet.Pilot.StepDispatcher.SpawnNamingTest do
  @moduledoc """
  The pod LABEL and the pod PROJECT are two objects, and this file exists to keep them two.

  `Fleet.Layout.pod_label/3` is the SINGLE builder of the human-facing name (terminal title + Claude
  Desktop entry). Every named spawn goes through it, so re-judging the format is a one-line change —
  which stays true only as long as nothing downstream reads the format back.
  """
  use ExUnit.Case, async: true

  alias Fleet.Layout
  alias Fleet.Spawner.Pod.LaunchSpec

  describe "pod_label/3 — the single starting point of the pod label" do
    test "with a ticket → <project>#<n>_<role>" do
      # With one producer pod per ticket, project+role no longer identifies a pod: two live
      # engineers of the same project differ ONLY by their number. Desktop has no sort (most recent
      # floats up), so the number IS what the human reads to tell them apart.
      assert Layout.pod_label("tetris", "engineer", 42) == "tetris#42_engineer"
    end

    test "without a ticket → <project>_<role> (project-bound pods: architect, recall)" do
      # Not a fallback: a pod that is NOT ticket-bound has no number to show, and printing a
      # placeholder would invent a ticket that does not exist.
      assert Layout.pod_label("tetris", "architect", nil) == "tetris_architect"
      assert Layout.pod_label("tetris", "architect") == "tetris_architect"
    end

    test "it takes the SLUG, never the owner/name pair (the caller slugs upstream)" do
      # Composing the two in the wrong order would put a `/` in a tmux session name.
      assert Layout.pod_label(Layout.project_slug("someone-else/tetris"), "scribe", 7) ==
               "tetris#7_scribe"
    end
  end

  describe "the label is a LABEL — regression wall against re-parsing it" do
    # A `#` in the label is exactly what breaks a parser: the old derivation stripped `_<role>` and
    # required the rest to be a slug, so `tetris#42_engineer` would have yielded `nil` — a pod with
    # no cwd remap, no intra-pod home and no checkpoint seed, booting happily on the wrong tree.
    # These two tests fail the moment anyone derives the project from the label again.
    test "a #-bearing label does not disturb the project: the slug travels on its own" do
      opts = [rc_name: Layout.pod_label("tetris", "engineer", 42), project_slug: "tetris"]

      assert LaunchSpec.rc_project(opts, cap()) == "tetris"
    end

    test "a label WITHOUT its slug yields nil — never a guess re-derived from the name" do
      # The spawn choke point refuses this pair upstream (`:project_required`), so it is unreachable
      # in production. Pinned here because the tempting "fix" for that guard is to re-derive the
      # slug from the label instead of refusing — the exact coupling this change removed.
      assert LaunchSpec.rc_project([rc_name: "tetris#42_engineer"], cap()) == nil
    end
  end

  describe "no second builder" do
    test "every producer of an rc_name goes through pod_label/3" do
      # The single starting point only holds if nobody rebuilds the label by hand. Three sites did
      # (dispatcher, architect, recall) and they had already drifted in what they interpolated. A
      # grep is the only mechanism that catches the fourth one arriving.
      root = Path.join(File.cwd!(), "lib")

      offenders =
        Path.join(root, "**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn f ->
          f
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.match?(line, ~r/rc_name:/) and not String.contains?(line, "pod_label(")
          end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(f, root)}:#{n} #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             "rc_name built outside Fleet.Layout.pod_label/3:\n" <> Enum.join(offenders, "\n")
    end
  end

  defp cap,
    do: %Fleet.CapProfile{kind: "CapProfile", metadata: %{"name" => "engineer"}, spec: %{}}
end
