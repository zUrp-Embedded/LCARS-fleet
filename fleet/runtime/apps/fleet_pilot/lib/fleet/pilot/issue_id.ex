defmodule Fleet.Pilot.IssueId do
  @moduledoc """
  Source UNIQUE du format `issue_id` stage-mode `"issue-<n>"`.

  `compose/1` et `parse/1` vivent ici → le writer (`Fleet.Pilot.StageDispatcher`) et le parser
  (`Fleet.Pilot.HopConsumer.parse_issue_number`, qui délègue) ne peuvent plus dériver l'un de
  l'autre. Le `issue_id` corrèle un pod à son issue forge tout au long du hop (enqueue → fin-de-hop).
  """

  @prefix "issue-"

  @doc ~S'''
  Compose le issue_id stage d'un numéro d'issue forge : `compose(42) => "issue-42"`.

  Tolérant : sémantiquement `"issue-" <> to_string(number)` (interpolation directe), donc tout terme
  est accepté ; le `number` attendu reste l'entier `issue["number"]`.
  '''
  @spec compose(integer()) :: String.t()
  def compose(number), do: @prefix <> to_string(number)

  @doc ~S'''
  Parse un issue_id stage `"issue-<n>"` → `{:ok, n}` ; sinon `:error`. Inverse STRICT de
  `compose/1` : le suffixe doit être un entier complet (`"issue-7x"` / `"issue-"` → `:error`).
  '''
  @spec parse(String.t()) :: {:ok, integer()} | :error
  def parse(@prefix <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse(_), do: :error
end
