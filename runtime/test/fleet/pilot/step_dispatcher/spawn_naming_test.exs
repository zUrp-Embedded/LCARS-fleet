defmodule Fleet.Pilot.StepDispatcher.SpawnNamingTest do
  @moduledoc """
  Keeps human pod labels independent from machine project slugs.
  Layout.pod_label/3 owns label formatting; consumers must receive the slug separately.
  """
  use ExUnit.Case, async: true

  alias Fleet.Layout
  alias Fleet.Spawner.Pod.LaunchSpec

  describe "pod_label/3 — the single starting point of the pod label" do
    test "with a ticket → <project>#<n>_<role>" do
      # Include the ticket to distinguish same-project/same-role work in desktop labels.
      assert Layout.pod_label("tetris", "engineer", 42) == "tetris#42_engineer"
    end

    test "without a ticket → <project>_<role> (project-bound pods: architect, recall)" do
      # A non-ticket pod must not display an invented number.
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
    # A ticket-bearing label breaks the old slug derivation; explicit project metadata must win.
    test "a #-bearing label does not disturb the project: the slug travels on its own" do
      opts = [rc_name: Layout.pod_label("tetris", "engineer", 42), project_slug: "tetris"]

      assert LaunchSpec.rc_project(opts, cap()) == "tetris"
    end

    test "a label WITHOUT its slug yields nil — never a guess re-derived from the name" do
      # Missing project metadata must not be repaired by guessing from the label.
      assert LaunchSpec.rc_project([rc_name: "tetris#42_engineer"], cap()) == nil
    end
  end

  describe "no second builder" do
    test "every producer of an rc_name goes through pod_label/3" do
      # Text scan detects rc_name keyword lines without pod_label on that line.
      # It also scans comments and is not an exhaustive AST check of all label construction.
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
             "rc_name built outside Layout.pod_label/3:\n" <> Enum.join(offenders, "\n")
    end
  end

  defp cap,
    do: %Fleet.CapProfile{kind: "CapProfile", metadata: %{"name" => "engineer"}, spec: %{}}
end
