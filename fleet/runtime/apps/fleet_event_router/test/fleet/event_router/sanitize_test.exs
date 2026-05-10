defmodule Fleet.EventRouter.SanitizeTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.Sanitize.{Secrets, PII}

  doctest Fleet.EventRouter.Sanitize.Secrets
  doctest Fleet.EventRouter.Sanitize.PII

  describe "Sanitize.Secrets.run/1" do
    test "redact sk-... token Anthropic" do
      result = Secrets.run("api: sk-1234567890abcdefghijk anything")
      assert result == "api: <TOKEN_REDACTED> anything"
    end

    test "redact ghp_... GitHub token" do
      ghp = "ghp_" <> String.duplicate("a", 36)
      result = Secrets.run("token=#{ghp} other")
      assert result == "token=<TOKEN_REDACTED> other"
    end

    test "redact multiples occurrences" do
      result = Secrets.run("first=sk-aaaaaaaaaaaaaaaaaaaa second=sk-bbbbbbbbbbbbbbbbbbbb")
      assert result == "first=<TOKEN_REDACTED> second=<TOKEN_REDACTED>"
    end

    test "ne touche pas les chaînes courtes (sk-XXX < 22 chars)" do
      result = Secrets.run("sk-short notatoken")
      assert result == "sk-short notatoken"
    end
  end

  describe "Sanitize.PII.run/1" do
    test "redact email simple" do
      result = PII.run("contact: alice@example.com")
      assert result == "contact: <EMAIL_REDACTED>"
    end

    test "redact email avec sous-domaine + chiffres + tirets" do
      result = PII.run("user.name+tag@sub-domain.co.uk")
      assert result == "<EMAIL_REDACTED>"
    end

    test "redact multiples emails" do
      result = PII.run("from a@b.com to c@d.com")
      assert result == "from <EMAIL_REDACTED> to <EMAIL_REDACTED>"
    end
  end

  describe "chaîne composable Secrets |> PII" do
    test "redact sequentiellement secrets puis emails" do
      input = "user alice@example.com utilise sk-1234567890abcdefghijk"
      result = input |> Secrets.run() |> PII.run()
      assert result == "user <EMAIL_REDACTED> utilise <TOKEN_REDACTED>"
    end

    test "ordre commutatif (résultat identique)" do
      input = "user alice@example.com utilise sk-1234567890abcdefghijk"
      r1 = input |> Secrets.run() |> PII.run()
      r2 = input |> PII.run() |> Secrets.run()
      assert r1 == r2
    end
  end
end
