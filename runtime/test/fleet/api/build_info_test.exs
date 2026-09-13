defmodule Fleet.API.BuildInfoTest do
  @moduledoc """
  Exercises env_facts directly, without Git fallback selection or release writing.
  LCARS_GIT_SHA is supplied by image builds without .git; the build ARG default
  unknown, empty and unset values must be refused. Other strings are not validated.
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
      # dirty:false is a fallback value, not evidence that the build tree was clean.
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
