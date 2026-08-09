defmodule Fleet.Workflow.Pinning do
  @moduledoc """
  What an agent EMITS on the forge: a short body on the surface, the full text committed and cited.

  The problem it solves is not verbosity. A long verdict pasted into a review is unreadable in the
  Gitea UI, it is unquotable (nothing addresses a version of it), and it is EDITABLE — a human who
  amends the comment amends the only copy, and nothing records that it changed. Committing the full
  text and citing `<ref> @ <sha>` makes the emission an immutable object with a name, and leaves on
  the surface exactly what a human scanning the PR needs.

  Below the threshold, this does nothing. A pointer to four lines costs more than the four lines —
  the reader has to follow it to learn there was nothing to follow.

  ## The failure semantic is the load-bearing part

  If the commit fails, the FULL BODY is posted inline and the failure is logged LOUD. A long comment
  is a cosmetic problem; a pointer to an object that does not exist is a lie, and it is the kind
  that survives — the reader assumes the doc is somewhere and blames its own search. Noisy rather
  than false, the same trade the retirement path already makes.

  ## The summary is a TRUNCATION, deliberately

  It keeps the first lines and says so. Anything cleverer — first paragraph, extracted headline —
  would let the summary misrepresent the body it points at, and the summary is the part a human
  reads and stops at. A truncation cannot claim something the text does not say.
  """

  require Logger

  alias Fleet.Workflow.OpsObjectSync

  # Above this, the body is committed and cited. Below, it is posted as-is. Set at the point where a
  # comment stops fitting in a glance in the Gitea UI — it is a readability threshold, not a cost
  # one: a LAN commit+push costs hundreds of milliseconds, which is not what makes an emission
  # expensive.
  @threshold_lines 10

  # How much of the body survives on the surface. The pinned form lands around 14 lines — LONGER
  # than a body that just fits under the threshold, and that is fine: the property that matters is
  # that it is BOUNDED. Thirty lines and five hundred produce the same fourteen, which is the whole
  # win. Trading summary lines to get under the threshold would buy a claim nobody needs and cost
  # the reader the only part they actually read.
  @summary_lines 8

  @doc """
  Renders `body` for posting: either as-is, or as a summary plus a `<kind>: <ref> @ <sha>` pointer.

  `opts`:
    * `:work_dir` — the project's ops worktree (REQUIRED to pin; absent → always inline)
    * `:ref` — ops-relative ref to commit at (REQUIRED to pin)
    * `:kind` — the pointer keyword and the noun of the disclaimer, e.g. `"Verdict"`
    * `:label` — commit-message prefix handed to `OpsObject` (default `"emission"`)
    * `:commit_fun` — seam (tests): `(work_dir, ref, content, opts) -> {:ok, sha, push_state} |
      {:error, term}`

  Always returns a body to post. It never returns an error: an emission that cannot be pinned is
  still an emission that must reach the forge.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(body, opts \\ []) when is_binary(body) do
    work_dir = Keyword.get(opts, :work_dir)
    ref = Keyword.get(opts, :ref)

    cond do
      not pinnable?(body) -> body
      is_nil(work_dir) or is_nil(ref) -> body
      true -> pin(body, work_dir, ref, opts)
    end
  end

  @doc "Is this body long enough to be worth pinning? Public so a caller can skip the work entirely."
  @spec pinnable?(String.t()) :: boolean()
  def pinnable?(body) when is_binary(body), do: line_count(body) > @threshold_lines

  defp pin(body, work_dir, ref, opts) do
    label = Keyword.get(opts, :label, "emission")
    commit = Keyword.get(opts, :commit_fun, &OpsObjectSync.commit_object/4)

    case commit.(work_dir, ref, body, label: label, push: :ops) do
      # `:local_only` does NOT fall back to inlining, and that is a deliberate asymmetry with the
      # commit failure below. A commit that did not happen leaves the pointer naming nothing, ever.
      # A push that did not land leaves an object that exists, is addressable by sha, and reaches
      # the forge at the branch's next successful push — the citation is late, not false. Inlining
      # it would trade a temporary lateness for a permanently unquotable wall of text.
      {:ok, sha, _push_state} ->
        pointer_body(body, ref, sha, Keyword.get(opts, :kind, "Doc"))

      {:error, reason} ->
        # INLINE, not a pointer. See the moduledoc: a dangling citation is worse than a long comment
        # because the reader trusts it and looks for the object.
        Logger.warning(
          "Emission: #{ref} NOT committed (#{inspect(reason)}) — full body posted inline instead " <>
            "of a pointer that would name nothing"
        )

        body
    end
  end

  defp pointer_body(body, ref, sha, kind) do
    """
    #{summary(body)}

    #{disclaimer(kind)}

    #{kind}: #{ref} @ #{sha}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # The architect's sentence, structure kept verbatim; only the NOUN follows what is being cited.
  # Saying "ordre de mission" over a verdict would be false, and the sentence exists precisely to
  # stop a reader from acting on the wrong artifact.
  defp disclaimer(kind) do
    "Ce qui précède est un résumé, pas le #{String.downcase(kind)}. Ce qui fait foi est le doc " <>
      "ci-dessous, à ce commit exact — éditer ce résumé ne le change pas."
  end

  defp summary(body) do
    lines = String.split(body, "\n")
    kept = Enum.take(lines, @summary_lines)
    dropped = length(lines) - length(kept)

    Enum.join(kept, "\n") <> "\n\n_(#{dropped} lignes de plus dans le doc cité)_"
  end

  defp line_count(body), do: body |> String.split("\n") |> length()
end
