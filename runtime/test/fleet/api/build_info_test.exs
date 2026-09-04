defmodule Fleet.API.BuildInfoTest do
  @moduledoc """
  The env fallback, and the three values it must REFUSE.

  A container build stage has no `.git` by construction, so `git rev-parse` fails there and the
  release used to be stamped `sha: "unknown"` — measured 2026-08-07 from inside a bench box, whose
  `fleet status` reported "build unknown ref= (source=release)". The fallback exists for that one
  path, and it is the ONLY way an image learns which code it runs.

  What these cases pin is the refusal side. `LCARS_GIT_SHA` is passed by a build ARG that DEFAULTS
  to the string "unknown", so an operator who builds without the box rail hands the fallback a
  sentinel rather than a revision. Accepting it would stamp the release with a plausible-looking
  fact that means the opposite of one — worse than the empty answer it replaces.
  """
  use ExUnit.Case, async: false

  alias Fleet.API.BuildInfo

  setup do
    previous = System.get_env("LCARS_GIT_SHA")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("LCARS_GIT_SHA")
        v -> System.put_env("LCARS_GIT_SHA", v)
      end
    end)

    :ok
  end

  describe "a revision passed by the build is carried through" do
    test "a real sha becomes the stamped fact" do
      System.put_env("LCARS_GIT_SHA", "deadbee")
      assert {:ok, %{sha: "deadbee", dirty: false, ref: nil}} = BuildInfo.env_facts()
    end

    test "dirty is false and ref is nil — NOT invented" do
      # A build context cannot know whether the tree was dirty, and it has no branch. Claiming
      # clean would be a statement; nil is the absence of one. The distinction matters the day
      # someone asks whether a shipped image came from a dirty tree.
      System.put_env("LCARS_GIT_SHA", "cafe123")
      {:ok, facts} = BuildInfo.env_facts()
      refute facts.dirty
      assert facts.ref == nil
    end
  end

  describe "the three refusals — a sentinel is not a revision" do
    test "unset falls through to :error" do
      System.delete_env("LCARS_GIT_SHA")
      assert BuildInfo.env_facts() == :error
    end

    test "empty falls through to :error" do
      System.put_env("LCARS_GIT_SHA", "")
      assert BuildInfo.env_facts() == :error
    end

    test "the literal \"unknown\" falls through — it is the ARG default, not a fact" do
      System.put_env("LCARS_GIT_SHA", "unknown")
      assert BuildInfo.env_facts() == :error
    end
  end
end
