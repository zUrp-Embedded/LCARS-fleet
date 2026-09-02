defmodule Fleet.Forge.PayloadFixture do
  @moduledoc """
  Forge payloads for witnesses, built from the REAL capture — never invented.

  A witness that stubs the forge needs the two or three values a decision branches on. It does not
  need a Gitea shape, and inventing one costs twice: the shape can be impossible, and it can be
  INCOMPLETE, which silently disarms any guard reading a field the fixture forgot. Both failures
  are on record in this repo — `{:no_head_sha, …}`, "a shape the forge cannot produce", and the
  probe wall that went mute across the whole suite because a double omitted one field.

  So the shape comes from `test/fixtures/forge/`, captured from a real forge whose digest was
  checked on the container. A witness states FACTS; the complete, real shape is supplied here.

      pull(head_ref: "lcars/issue-42-engineer", merged: true)
      issue(label_names: ["lcars-in-flight"])

  ⚠ THE WRITER GOES THROUGH `Payload.paths/0`, THE SAME TABLE THE READER USES. That is what keeps
  the two from drifting: a path changed in one place moves the builder and the reader together, and
  `payload_fixture_test.exs` round-trips every fact to prove it.

  Projected facts (`label_names`, `assignee_logins`) need an explicit writer: reading them flattens
  objects to names, so writing them has to rebuild the objects — the clauses of `ecrire/2`.
  """

  alias Fleet.Forge.Payload

  @dir Path.join([__DIR__, "..", "..", "fixtures", "forge"])
  @external_resource Path.join(@dir, "pr.json")
  @external_resource Path.join(@dir, "issue.json")
  @external_resource Path.join(@dir, "repo.json")

  @pull @dir |> Path.join("pr.json") |> File.read!() |> Jason.decode!()
  @issue @dir |> Path.join("issue.json") |> File.read!() |> Jason.decode!()
  @repo @dir |> Path.join("repo.json") |> File.read!() |> Jason.decode!()

  @doc "A real pull request, with the stated facts overridden."
  @spec pull(keyword()) :: Payload.t()
  def pull(faits \\ []), do: apply_faits(@pull, faits)

  @doc "A real issue, with the stated facts overridden."
  @spec issue(keyword()) :: Payload.t()
  def issue(faits \\ []), do: apply_faits(@issue, faits)

  @doc "A real repository, with the stated facts overridden."
  @spec repo(keyword()) :: Payload.t()
  def repo(faits \\ []), do: apply_faits(@repo, faits)

  @doc "The captured payload, untouched — for a witness that asserts on the real shape itself."
  @spec raw(:pull | :issue | :repo) :: Payload.t()
  def raw(:pull), do: @pull
  def raw(:issue), do: @issue
  def raw(:repo), do: @repo

  defp apply_faits(payload, faits) do
    Enum.reduce(faits, payload, fn {fait, valeur}, acc ->
      chemin =
        Payload.paths()[fait] ||
          raise ArgumentError,
                "#{inspect(fait)} is not a declared fact of Fleet.Forge.Payload — " <>
                  "declare its path there rather than writing a raw key here"

      put_chemin(acc, chemin, ecrire(fait, valeur))
    end)
  end

  # Les faits dont la LECTURE est une projection : le fil porte des objets, le lecteur rend des
  # noms. L'ecriture doit donc les reconstruire.
  defp ecrire(:label_names, noms), do: Enum.map(noms, &%{"name" => &1})
  defp ecrire(:assignee_logins, logins), do: Enum.map(logins, &%{"login" => &1})
  defp ecrire(_fait, valeur), do: valeur

  # `put_in/3` refuses a path whose intermediate key is absent; the capture always carries them for
  # its own type, but an issue has no `head`. Building the missing level is the honest behaviour: a
  # witness that states `head_ref:` on an issue is asking for a shape the forge does not produce,
  # and it should get the value it asked for rather than a silent no-op.
  defp put_chemin(map, [clef], valeur), do: Map.put(map, clef, valeur)

  defp put_chemin(map, [clef | reste], valeur) do
    sous = if is_map(Map.get(map, clef)), do: Map.get(map, clef), else: %{}
    Map.put(map, clef, put_chemin(sous, reste, valeur))
  end
end
