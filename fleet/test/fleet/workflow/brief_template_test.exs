defmodule Fleet.Workflow.BriefTemplateTest do
  @moduledoc """
  The calibration-template renderer (F-23): prose is priv DATA, code fills slots, and every
  miswiring fails LOUD — an agent must never receive a half-rendered order.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.BriefTemplate

  test "renders a real template with all slots filled (substitution without evaluation)" do
    out =
      BriefTemplate.render("work-order-build", %{
        "role" => "engineer",
        "issue" => "3",
        "brief_body" => "Do X.",
        "brief_source" => "brief inline du ticket"
      })

    assert out =~ "# Ordre de mission — engineer — ticket #3"
    assert out =~ "Do X."
    refute out =~ "{{"
  end

  test "a token value containing {{...}} still fails the leftover belt (never ships half-rendered)" do
    # Substitution is NOT evaluation: an injected `{{token}}` in DATA is not re-substituted —
    # but the belt refuses to ship it (a brief with live-looking slots is a calibration error).
    assert_raise ArgumentError, ~r/unresolved token/, fn ->
      BriefTemplate.render("work-order-build", %{
        "role" => "engineer",
        "issue" => "3",
        "brief_body" => "sneaky {{signature}}",
        "brief_source" => "brief inline du ticket",
        "signature" => "SIGN"
      })
    end
  end

  test "missing template file → raises (File.Error), never a silent fallback" do
    assert_raise File.Error, fn -> BriefTemplate.render("does-not-exist", %{}) end
  end

  test "token absent from assigns → raises (KeyError) — a calibration error is LOUD" do
    assert_raise KeyError, fn -> BriefTemplate.render("work-order-build", %{"role" => "x"}) end
  end
end
