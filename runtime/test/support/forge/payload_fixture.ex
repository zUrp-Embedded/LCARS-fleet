defmodule Fleet.Forge.PayloadFixture do
  @moduledoc """
  Forge test payloads based on test/fixtures/forge/ captures, with selected facts overridden.
  Keeping unrelated captured fields avoids missing-field fallbacks (e.g. probe guards or no_head_sha)
  in tests that only intend to change one decision input.

      pull(head_ref: "lcars/issue-42-engineer", merged: true)
      issue(label_names: ["lcars-in-flight"])

  Writes use Payload.paths, so a shared wrong path can pass a round-trip test. Tests separately
  check resolution on raw captures and round-trip the explicit list projections.
  Overrides are not schema-validated and can produce combinations the forge would never return.
  """

  alias Fleet.Forge.Payload

  @dir Path.join([__DIR__, "..", "..", "fixtures", "forge"])
  @external_resource Path.join(@dir, "pr.json")
  @external_resource Path.join(@dir, "issue.json")
  @external_resource Path.join(@dir, "repo.json")

  @pull @dir |> Path.join("pr.json") |> File.read!() |> Jason.decode!()
  @issue @dir |> Path.join("issue.json") |> File.read!() |> Jason.decode!()
  @repo @dir |> Path.join("repo.json") |> File.read!() |> Jason.decode!()

  @doc "The captured pull request with stated facts overridden, without schema validation."
  @spec pull(keyword()) :: Payload.t()
  def pull(faits \\ []), do: apply_faits(@pull, faits)

  @doc "The captured issue with stated facts overridden, without schema validation."
  @spec issue(keyword()) :: Payload.t()
  def issue(faits \\ []), do: apply_faits(@issue, faits)

  @doc "The captured repository with stated facts overridden, without schema validation."
  @spec repo(keyword()) :: Payload.t()
  def repo(faits \\ []), do: apply_faits(@repo, faits)

  @doc "The captured payload, untouched — for a witness that asserts on the real shape itself."
  @spec raw(:pull | :issue | :repo) :: Payload.t()
  def raw(:pull), do: @pull
  def raw(:issue), do: @issue
  def raw(:repo), do: @repo

  # Delegation reads the plural before the singular: mirror a binary/nil assignee_login into
  # the list unless explicitly supplied, avoiding a stale captured assignee overriding the test.
  defp apply_faits(payload, faits) do
    faits =
      case {Keyword.fetch(faits, :assignee_login), Keyword.has_key?(faits, :assignee_logins)} do
        {{:ok, login}, false} when is_binary(login) -> faits ++ [assignee_logins: [login]]
        {{:ok, nil}, false} -> faits ++ [assignee_logins: []]
        _ -> faits
      end

    Enum.reduce(faits, payload, fn {fait, valeur}, acc ->
      chemin =
        Payload.paths()[fait] ||
          raise ArgumentError,
                "#{inspect(fait)} is not a declared fact of Payload — " <>
                  "declare its path there rather than writing a raw key here"

      put_chemin(acc, chemin, ecrire(fait, valeur))
    end)
  end

  # Rebuild objects for readers that project names.
  defp ecrire(:label_names, noms), do: Enum.map(noms, &%{"name" => &1})
  defp ecrire(:assignee_logins, logins), do: Enum.map(logins, &%{"login" => &1})
  defp ecrire(_fait, valeur), do: valeur

  # Rebuild absent/non-map intermediate levels, including synthetic fields like head on an issue.
  defp put_chemin(map, [clef], valeur), do: Map.put(map, clef, valeur)

  defp put_chemin(map, [clef | reste], valeur) do
    sous = if is_map(Map.get(map, clef)), do: Map.get(map, clef), else: %{}
    Map.put(map, clef, put_chemin(sous, reste, valeur))
  end
end
