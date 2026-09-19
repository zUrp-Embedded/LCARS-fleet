defmodule Fleet.FactsTest do
  @moduledoc """
  The Elixir reader of `etc/facts.env`, branch by branch, on injected candidates.

  ⚖ Decision 3. Three things decide whether this rail agrees with the other three, and each is
  measured here: the ORDER (environment over file — a value provisioning carries must win), the
  REFUSAL (an unreadable file raises instead of yielding an empty string, the failure that would
  send a daemon writing to the filesystem root), and the FORM (`KEY=value`, no expansion, so a
  reader does not have to speak shell).

  The candidate list and the environment reader are injected: nothing here touches the machine's
  own `/opt/lcars`, and a bench installed beside the checkout cannot make a case pass or fail.
  """
  use ExUnit.Case, async: true

  alias Fleet.Facts

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    file = Path.join(tmp, "facts.env")

    File.write!(file, """
    # a comment, and a blank line follow

    LCARS_FLEET_GROUP=fleet
    LCARS_PRIVATE_DIR=/opt/lcars/var/tokens
    pas_un_fait
    """)

    {:ok, faits: file, opts: [candidates: [file], env: fn _ -> nil end]}
  end

  describe "reading a fact" do
    test "the file answers when the environment is silent", ctx do
      assert Facts.get!("LCARS_FLEET_GROUP", ctx.opts) == "fleet"
    end

    test "THE ENVIRONMENT WINS — what provisioning carries beats the declared default", ctx do
      opts = Keyword.put(ctx.opts, :env, fn "LCARS_FLEET_GROUP" -> "flotte" end)

      assert Facts.get!("LCARS_FLEET_GROUP", opts) == "flotte"
    end

    test "an empty environment value is not an answer — the file still decides", ctx do
      opts = Keyword.put(ctx.opts, :env, fn _ -> "" end)

      assert Facts.get!("LCARS_FLEET_GROUP", opts) == "fleet"
    end

    test "an unknown fact raises, and the message names the key and the file read", ctx do
      assert_raise ArgumentError, fn -> Facts.get!("LCARS_NULLE_PART", ctx.opts) end

      message =
        try do
          Facts.get!("LCARS_NULLE_PART", ctx.opts)
        rescue
          e in ArgumentError -> Exception.message(e)
        end

      assert message =~ "LCARS_NULLE_PART"
      assert message =~ ctx.faits
    end

    test "`get/3` covers a missing KEY with its default", ctx do
      assert Facts.get("LCARS_NULLE_PART", "replié", ctx.opts) == "replié"
    end
  end

  describe "an unreadable facts file" do
    test "RAISES — a fact that could not be read is not an empty string", ctx do
      opts = Keyword.put(ctx.opts, :candidates, [Path.join(ctx.tmp_dir, "absent.env")])

      assert_raise File.Error, fn -> Facts.get!("LCARS_FLEET_GROUP", opts) end
    end

    test "a missing KEY still raises when the default would have covered it", ctx do
      opts = Keyword.put(ctx.opts, :candidates, [Path.join(ctx.tmp_dir, "absent.env")])

      assert_raise File.Error, fn -> Facts.get("LCARS_FLEET_GROUP", "replié", opts) end
    end

    test "`path/1` answers nil rather than guessing", ctx do
      opts = Keyword.put(ctx.opts, :candidates, [Path.join(ctx.tmp_dir, "absent.env")])

      assert Facts.path(opts) == nil
    end
  end

  describe "the candidates" do
    test "the FIRST readable one is retained — a checkout is read before an installed machine",
         ctx do
      absent = Path.join(ctx.tmp_dir, "absent.env")
      opts = Keyword.put(ctx.opts, :candidates, [absent, ctx.faits])

      assert Facts.path(opts) == ctx.faits
    end

    test "`LCARS_FACTS_FILE` passes in front of both, like on the shell side", ctx do
      autre = Path.join(ctx.tmp_dir, "autre.env")
      File.write!(autre, "LCARS_FLEET_GROUP=flottille\n")

      opts = [env: fn "LCARS_FACTS_FILE" -> autre end]

      assert Facts.path(opts) == autre
    end
  end

  describe "the format" do
    test "comments, blanks and lines without `=` are not facts", ctx do
      faits = Facts.load!(ctx.opts)

      assert Map.keys(faits) |> Enum.sort() == ["LCARS_FLEET_GROUP", "LCARS_PRIVATE_DIR"]
    end

    test "NO EXPANSION: a `$` is a character, not a shell variable" do
      assert Facts.parse("LCARS_X=$LCARS_Y/suite\n") == %{"LCARS_X" => "$LCARS_Y/suite"}
    end

    test "a value may carry `=`; only the first one splits" do
      assert Facts.parse("LCARS_X=a=b\n") == %{"LCARS_X" => "a=b"}
    end
  end

  describe "the shipped file" do
    test "the four rails read the SAME file, and it carries the org the runtime configures" do
      # No injection here on purpose: this case measures the file the release actually ships.
      faits = Facts.load!(candidates: ["etc/facts.env"])

      assert faits["LCARS_FORGE_ORG"] != nil
      assert faits["LCARS_PRIVATE_DIR"] != nil
      refute Enum.any?(faits, fn {_k, v} -> String.contains?(v, "$") end)
    end
  end
end
