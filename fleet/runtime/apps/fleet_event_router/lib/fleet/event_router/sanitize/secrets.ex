defmodule Fleet.EventRouter.Sanitize.Secrets do
  @moduledoc """
  Sanitize chain station 1 — redact secrets API tokens (PoC-7 PROVEN).

  Marker : `<TOKEN_REDACTED>`. Travaille sur le `.text` du JSON parsé,
  pas sur la ligne brute (PoC-7 lesson : éviter de masquer du
  payload structurel par accident).

  Patterns matchés :
    * `sk-[a-zA-Z0-9]{20,}` — Anthropic / OpenAI
    * `ghp_[a-zA-Z0-9]{36}` — GitHub personal access token
  """

  @marker "<TOKEN_REDACTED>"
  @pattern ~r/sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}/

  @doc """
  Applique la redaction sur une chaîne de texte.

  ## Examples

      iex> Fleet.EventRouter.Sanitize.Secrets.run("token=sk-abc123def456ghi789jkl000")
      "token=<TOKEN_REDACTED>"

      iex> Fleet.EventRouter.Sanitize.Secrets.run("plain text")
      "plain text"
  """
  @spec run(String.t()) :: String.t()
  def run(text) when is_binary(text) do
    Regex.replace(@pattern, text, @marker)
  end
end
