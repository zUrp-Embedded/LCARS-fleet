defmodule Fleet.EventRouter.Sanitize.PII do
  @moduledoc """
  Sanitize chain station 2 — redact PII emails (PoC-7 PROVEN).

  Marker : `<EMAIL_REDACTED>`. Composable avec `Sanitize.Secrets` :
  `text |> Secrets.run() |> PII.run()`.
  """

  @marker "<EMAIL_REDACTED>"
  @pattern ~r/[\w._%+-]+@[\w.-]+\.\w{2,}/

  @doc """
  Applique la redaction PII sur une chaîne de texte.

  ## Examples

      iex> Fleet.EventRouter.Sanitize.PII.run("contact: alice@example.com")
      "contact: <EMAIL_REDACTED>"

      iex> Fleet.EventRouter.Sanitize.PII.run("plain text")
      "plain text"
  """
  @spec run(String.t()) :: String.t()
  def run(text) when is_binary(text) do
    Regex.replace(@pattern, text, @marker)
  end
end
