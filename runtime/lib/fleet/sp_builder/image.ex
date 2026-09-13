defmodule Fleet.SPBuilder.Image do
  @moduledoc """
  Root-keyed snapshots of prompt artifacts in persistent_term. Readers keep published
  bytes until republishing and distinguish an absent image from a missing image entry.
  Publication checks presence/nonempty selected artifacts, not their semantic safety.
  Content reads and source fingerprints are separate passes, not an atomic disk snapshot.
  """

  require Logger

  alias Fleet.Catalogue

  @doc """
  Publishes installed catalogue scopes sequentially, each combining its own and system
  artifacts. Required artifact sets must be nonempty; subagent templates may be absent.
  Selected empty files and unreadable listed sources raise. This does not validate every
  directory or required filename. Earlier scopes remain published if a later one fails;
  images for roots no longer installed are not erased. The caller applies the
  :sp_builder_publish_image switch; this function does not check it.
  """
  @spec publish!() :: :ok
  def publish! do
    # Separate keys prevent same-named roles in different business catalogues sharing an image.
    for root <- Catalogue.installed_roots(), do: publish_scope!(root)
    :ok
  end

  defp publish_scope!(root) do
    ensure_declared_roles_carry_an_sp!(root)

    image = %{
      modop_sp:
        read_dir_map!(modop_roots(root), "*/sp.md", &(&1 |> Path.dirname() |> Path.basename())),
      # Empty corpus is valid. A role naming an absent template fails during composition;
      # publication only rejects empty selected files, not every possible truncation.
      subagent:
        read_dir_map(
          subagent_roots(root),
          "subagent-*.md",
          &(&1 |> Path.basename(".md") |> String.replace_prefix("subagent-", ""))
        ),
      drafts:
        read_dir_map!(
          drafts_roots(root),
          "agent-*-base.md",
          &(&1
            |> Path.basename(".md")
            |> String.replace_prefix("agent-", "")
            |> String.replace_suffix("-base", ""))
        ),
      worker_protocol: read_worker_protocol!(root),
      human_protocol: read_protocol!(human_protocol_path(root), "human protocol"),
      # systemPrompt selects a role draft. EEx is frozen as source, evaluated later by SPBuilder.
      templates: read_dir_map!(template_roots(root), "*.eex", &Path.basename(&1))
    }

    # Re-read sources for drift tracking, including shadowed files. Concurrent edits can make
    # these hashes disagree with the bytes already placed in image; publish from a quiescent tree.
    sources = source_fingerprints(root)

    # A 48-bit trace stamp like CapProfile.Image's, not a durable/collision-free identity.
    # Uses OTP term encoding of content, excluding source paths/hashes; changing encoding
    # would change existing stamps even if prompt bytes stayed the same.
    version =
      :crypto.hash(:sha256, :erlang.term_to_binary(image))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    :persistent_term.put(
      image_key(root),
      image |> Map.put(:version, version) |> Map.put(:sources, sources)
    )

    Logger.info(
      "SPBuilder.Image: published (#{map_size(image.modop_sp)} modop fragments, " <>
        "#{map_size(image.subagent)} subagent templates, #{map_size(image.drafts)} drafts, " <>
        "#{map_size(image.templates)} EEx templates, " <>
        "worker + human protocols frozen, version=#{version})"
    )

    :ok
  end

  # Check declaration ownership within this business/system pair, not unrelated catalogues.
  # A draft-only override needs no YAML. A declared role needs a local draft or declared reuse
  # in at least one tree declaring that name; fine path overrides are outside this direct-root scan.
  defp ensure_declared_roles_carry_an_sp!(scope_root) do
    # OR across declarations lets a business copy of a system role reuse the system's prompt.
    carried = Enum.reduce([scope_root, Catalogue.system_root()], %{}, &carried_in_root/2)

    orphans = carried |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    unless orphans == [] do
      raise "SPBuilder.Image: #{Enum.join(orphans, ", ")} — declared by a catalogue that carries " <>
              "no SP for them. A catalogue that DECLARES a role owes its prompt: " <>
              "`agent-<role>-base.md` in its own sp_drafts, or `spec.systemPrompt` naming the role " <>
              "it reuses. Carrying the draft ALONE is the legal gesture (superseding a role you did " <>
              "not write) and is never reported here. Proven-good image at boot, or do not boot."
    end

    :ok
  end

  # Any binary systemPrompt counts, even empty/unresolvable; actual resolution belongs to
  # the asset reader/spawn proof. Index errors skip this tree rather than failing this guard.
  defp carried_in_root(root, acc) do
    cap_dir = Path.join(root, Catalogue.rel(:cap_profiles))
    drafts_dir = Path.join(root, Catalogue.rel(:sp_drafts))

    case Fleet.CapProfile.index_of(cap_dir) do
      {:ok, index} ->
        Enum.reduce(Map.keys(index), acc, fn role, acc ->
          carried? = sp_carried?(index, drafts_dir, role)
          Map.update(acc, role, carried?, &(&1 or carried?))
        end)

      {:error, _} ->
        acc
    end
  end

  defp sp_carried?(index, drafts_dir, role) do
    borrowed = index |> Map.get(role, %{}) |> get_in(["spec", "systemPrompt"])

    is_binary(borrowed) or File.regular?(Path.join(drafts_dir, "agent-#{role}-base.md"))
  end

  @doc """
  Compares the default catalogue image's recorded source hashes with current disk bytes.
  Returns sorted modified/vanished paths, or :unpublished. Any read error is :vanished.
  Does not detect newly added files or inspect other business images. Empty results mean
  recorded sources match their fingerprint pass, not proof they match the earlier content
  reads. The function returns findings without logging them or changing the published image.
  """
  @spec drift() :: {:ok, [{Path.t(), :modified | :vanished}]} | :unpublished
  def drift do
    case published() do
      %{sources: sources} ->
        {:ok,
         sources
         |> Enum.flat_map(fn {path, sha} ->
           case File.read(path) do
             {:ok, content} -> if sha_of(content) == sha, do: [], else: [{path, :modified}]
             {:error, _} -> [{path, :vanished}]
           end
         end)
         |> Enum.sort()}

      _ ->
        :unpublished
    end
  end

  # Keep globs aligned with image sections or added sections escape drift tracking.
  defp source_fingerprints(root) do
    # Include both business and system files, even shadowed ones omitted from the content map.
    [
      {modop_roots(root), "*/sp.md"},
      {subagent_roots(root), "subagent-*.md"},
      {drafts_roots(root), "agent-*-base.md"},
      {template_roots(root), "*.eex"}
    ]
    |> Enum.flat_map(fn {roots, glob} ->
      Enum.flat_map(roots, &(&1 |> Path.join(glob) |> Path.wildcard()))
    end)
    |> Enum.concat([worker_protocol_path(root), human_protocol_path(root)])
    |> Enum.uniq()
    |> Map.new(&{&1, &1 |> read_artifact!("fingerprinted source") |> sha_of()})
  end

  # Listed paths can vanish before reading; returned errors name that condition. Empty-content
  # checks live in callers. A missing protocol lookup can pass nil and raise before this case.
  defp read_artifact!(path, what) do
    case File.read(path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        raise "SPBuilder.Image: #{what} #{path} was listed, then unreadable (#{inspect(reason)}) — " <>
                "the prompt material moved DURING publication, so the epoch cannot cover what it " <>
                "would serve. Republish against a tree at rest. Proven-good image at boot, or do " <>
                "not boot."
    end
  end

  defp sha_of(content), do: :crypto.hash(:sha256, content)

  @doc "Returns a catalogue image or nil; no argument selects the current Catalogue.root/0."
  @spec published() :: map() | nil
  def published do
    published(Catalogue.root())
  end

  @spec published(Path.t()) :: map() | nil
  def published(root) when is_binary(root), do: :persistent_term.get(image_key(root), nil)

  @doc "Erases every published image — TESTS ONLY."
  @spec unpublish() :: :ok
  def unpublish do
    for {key, _} <- :persistent_term.get(), match?({__MODULE__, :image, _}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  @doc """
  Test helper restoring an unchecked image at the current Catalogue.root/0. Restore the
  root configuration first; this does not restore every image erased by unpublish/0.
  Using this helper keeps tests independent of the persistent_term key representation.
  """
  @spec republish(map()) :: :ok
  def republish(%{} = image) do
    :persistent_term.put(image_key(Catalogue.root()), image)
    :ok
  end

  defp image_key(root), do: {__MODULE__, :image, root}

  @doc """
  The role's SP draft from the published image (`{:ok, content}`), `:not_found` if the image is
  published but carries no draft for `role` (closed world), `:unpublished` otherwise (the
  caller falls back to disk). Consulted by the spawner's Assets rail.
  """
  @spec draft(String.t()) :: {:ok, binary()} | :not_found | :unpublished
  def draft(role) when is_binary(role), do: draft(role, nil)

  @doc """
  Reads the named root's draft image; nil selects Catalogue.root/0. Profile-aware callers
  pass catalogue_root so a same-named role in another catalogue cannot supply its draft.
  """
  @spec draft(String.t(), Path.t() | nil) :: {:ok, binary()} | :not_found | :unpublished
  def draft(role, root) when is_binary(role) do
    case published_or_default(root) do
      %{drafts: drafts} ->
        case Map.fetch(drafts, role) do
          {:ok, content} -> {:ok, content}
          :error -> :not_found
        end

      nil ->
        :unpublished
    end
  end

  @doc """
  Returns the frozen worker protocol or :unpublished. Publication honours the
  :spawner_protocole_user_path override used by the disk consumer; later disk edits do
  not change these bytes until republished. nil root selects the default catalogue.
  """
  @spec worker_protocol() :: {:ok, binary()} | :unpublished
  def worker_protocol, do: worker_protocol(nil)

  @spec worker_protocol(Path.t() | nil) :: {:ok, binary()} | :unpublished
  def worker_protocol(root) do
    case published_or_default(root) do
      %{worker_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

  @doc """
  The conversation contract added for a human interlocutor (`{:ok, content}`) or `:unpublished`.
  """
  @spec human_protocol() :: {:ok, binary()} | :unpublished
  def human_protocol, do: human_protocol(nil)

  @spec human_protocol(Path.t() | nil) :: {:ok, binary()} | :unpublished
  def human_protocol(root) do
    case published_or_default(root) do
      %{human_protocol: content} -> {:ok, content}
      nil -> :unpublished
    end
  end

  defp published_or_default(nil), do: published()
  defp published_or_default(root) when is_binary(root), do: published(root)

  @doc """
  An EEx template SOURCE by file name (`"sp_template.eex"`): `{:ok, source}`, `:not_found`
  (closed world) or `:unpublished`.
  """
  @spec template(String.t()) :: {:ok, binary()} | :not_found | :unpublished
  def template(name) when is_binary(name), do: lookup(:templates, name)

  defp lookup(section, key) do
    case published() do
      nil ->
        :unpublished

      image ->
        case image |> Map.fetch!(section) |> Map.fetch(key) do
          {:ok, content} -> {:ok, content}
          :error -> :not_found
        end
    end
  end

  defp read_dir_map!(roots, glob, key_fun) when is_list(roots) do
    if Enum.all?(roots, &(Path.wildcard(Path.join(&1, glob)) == [])) do
      raise "SPBuilder.Image: no artifact matches #{glob} under #{inspect(roots)} — " <>
              "proven-good image at boot, or do not boot (broken deploy?)"
    end

    read_dir_map(roots, glob, key_fun)
  end

  # Allows zero matching files; nonempty selected content is still required.
  defp read_dir_map(roots, glob, key_fun) when is_list(roots) do
    # First key wins; the later fingerprint pass still reads shadowed sources.
    Enum.reduce(roots, %{}, fn root, acc ->
      root
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.reduce(acc, &put_first_seen(&2, key_fun.(&1), &1))
    end)
  end

  # Reject exactly empty selected files; whitespace-only content is accepted.
  defp put_first_seen(inner, key, path) do
    if Map.has_key?(inner, key) do
      inner
    else
      content = read_artifact!(path, "artifact")

      if content == "" do
        raise "SPBuilder.Image: artifact #{path} is empty — proven-good image requires " <>
                "non-empty artifacts (truncated file in deploy?)"
      end

      Map.put(inner, key, content)
    end
  end

  defp read_worker_protocol!(root),
    do: read_protocol!(worker_protocol_path(root), "worker protocol")

  defp read_protocol!(path, label) do
    content = read_artifact!(path, label)

    if content == "" do
      raise "SPBuilder.Image: #{label} is empty — proven-good image requires non-empty artifacts"
    end

    content
  end

  # Match Pod.Assets' override without introducing a reverse module dependency.
  defp worker_protocol_path(root) do
    Application.get_env(:lcars_fleet, :spawner_protocole_user_path) ||
      Catalogue.find_in(
        Catalogue.tree_scope(root, :sp_drafts),
        "protocole-user-worker.md"
      )
  end

  # Human protocol overrides use the catalogue search path, not a second per-file config knob.
  defp human_protocol_path(root),
    do:
      Catalogue.find_in(
        Catalogue.tree_scope(root, :sp_drafts),
        "protocole-user-human.md"
      )

  # Scope order is business (or fine override), then system, omitting absent directories.
  # Draft/subagent disk readers match this scope; SPBuilder's modop disk fallback remains global.
  defp modop_roots(root), do: Catalogue.tree_scope(root, :modops)

  defp subagent_roots(root), do: Catalogue.tree_scope(root, :subagent_templates)

  defp drafts_roots(root), do: Catalogue.tree_scope(root, :sp_drafts)

  defp template_roots(root), do: Catalogue.tree_scope(root, :sp_templates)
end
