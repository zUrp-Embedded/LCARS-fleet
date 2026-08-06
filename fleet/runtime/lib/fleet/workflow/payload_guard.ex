defmodule Fleet.Workflow.PayloadGuard do
  @moduledoc """
  Placement + SECURITY-validation of an UNTRUSTED file payload into a
  workspace: "write what the pod produced, without letting it escape the
  workspace or arm the world-side git plumbing". Standalone filter, extracted
  from `Fleet.Workflow.Deliverable` — it knows nothing
  about deliverable modes, the gate, nor the push: it only knows a workspace
  and an adversarial `%{"path" => …, "content" => …}` list.

  SINGLE source of payload application: one sole authority for deliverable
  placement (a divergent placement is made unrepresentable). 2 passes:
  (1) validate ALL paths before any write — a partially INVALID payload writes
  NOTHING; (2) write — a `File.write` failure mid-pass stops there and returns
  the error, files already written REMAIN (no rollback), but the caller
  (`Deliverable.materialize_content`) short-circuits on the error so nothing
  partial is ever committed.

  ## The 4 closed vectors (fail-closed, first refusal returned)

    * **Path traversal** — the `Path.expand` of the join must stay under the
      workspace (a `../` resolved outside the root → `{:path_traversal, path}`).
    * **`.git` component** — a payload writing UNDER `.git/` (at any level)
      would rewrite the repo config: `.git/config` (arming a
      `filter.<name>.clean` executed by the system-side `git add` that
      follows), `.git/hooks/pre-commit`, etc. → arbitrary command execution
      world-side at commit time. The pod NEVER lays down its own git plumbing
      via the payload → `{:dotgit_path, path}`. (The system-side commit is what
      turns this content into a deliverable, so the payload is consumed AFTER
      the write → the guard MUST be here, before the write.)
    * **armed `.gitattributes`** — a `.gitattributes` whose content ARMS a
      `filter=` or a `diff=` diverts system-side `git add`/`git log -p` toward
      an external command. `core.attributesFile=/dev/null` neutralizes ONLY
      the GLOBAL file; the IN-TREE `.gitattributes` stays honored and is NOT
      disablable via `-c` (git has no "disable all filters"). The ONLY real
      lock on this vector is therefore THIS content refusal →
      `{:dangerous_gitattributes, path}`. `Fleet.Credentials.Shell` closes the
      GLOBAL-config vector with `core.attributesFile=/dev/null` and leaves this
      one to us ON PURPOSE — weakening the clause below removes the only net,
      and nothing upstream will catch it.
    * **Symlink in the chain** — `Path.expand` is LEXICAL (resolves `..`, NOT
      symlinks): a symlink checked into the cloned repo
      (`out -> /home/<human>/.claude`) passes the prefix check, but
      `File.write` FOLLOWS the symlink → write OUTSIDE the workspace. Refuse if
      an EXISTING component of the path is a symlink → `{:symlink_escape, path}`.

  The single public entry (`apply_files/2`) chains validation then write:
  writing without validating is impossible by construction (validation is not
  an optional exposed step).
  """

  @doc """
  Validates then writes `files` (list of `%{"path" => rel, "content" => bin}`)
  under `workspace`. 2 passes: EVERYTHING is validated (cf. moduledoc —
  traversal, `.git`, armed `.gitattributes`, symlink) before the SLIGHTEST
  write.

  ## Exit codes
    * `:ok` — all files written
    * `{:error, :no_files_in_payload}` — empty list or not a list
    * `{:error, {:invalid_payload_file, repr}}` — entry without binary
      `path`/`content`, or empty `path` (a path `""` would pass the checks then
      `File.write` on the dir = opaque `:eisdir` — clean rejection upstream)
    * `{:error, {:path_traversal | :dotgit_path | :dangerous_gitattributes |
      :symlink_escape, rel_path}}` — vector refused (nothing is written)
    * `{:error, {:file_write_failed, rel_path, reason}}` — write KO in pass 2
      (files already written remain — no rollback; the caller stops on the
      error, so the partial state is never committed)
  """
  @spec apply_files(Path.t(), term()) :: :ok | {:error, term()}
  def apply_files(workspace, files) when is_list(files) and files != [] do
    with :ok <- validate_files(workspace, files) do
      write_validated_files(workspace, files)
    end
  end

  def apply_files(_workspace, _other), do: {:error, :no_files_in_payload}

  defp validate_files(workspace, files) do
    expanded_ws = Path.expand(workspace)

    Enum.reduce_while(files, :ok, fn
      # Empty path would otherwise become an opaque directory write error.
      %{"path" => rel_path, "content" => content}, :ok
      when is_binary(rel_path) and rel_path != "" and is_binary(content) ->
        full = Path.expand(Path.join(workspace, rel_path))

        cond do
          not (full == expanded_ws or String.starts_with?(full, expanded_ws <> "/")) ->
            {:halt, {:error, {:path_traversal, rel_path}}}

          dotgit_component?(rel_path) ->
            {:halt, {:error, {:dotgit_path, rel_path}}}

          gitattributes_basename?(rel_path) and arms_filter_or_diff?(content) ->
            {:halt, {:error, {:dangerous_gitattributes, rel_path}}}

          symlink_in_chain?(workspace, rel_path) ->
            {:halt, {:error, {:symlink_escape, rel_path}}}

          true ->
            {:cont, :ok}
        end

      bad, :ok ->
        {:halt, {:error, {:invalid_payload_file, inspect(bad)}}}
    end)
  end

  # Match `.git` as a path component, not `.gitignore` or `foo.git`.
  defp dotgit_component?(rel_path) do
    rel_path |> Path.split() |> Enum.any?(&(&1 == ".git"))
  end

  # `.gitattributes` can arm Git filter or diff drivers at any depth.
  defp gitattributes_basename?(rel_path) do
    Path.basename(rel_path) == ".gitattributes"
  end

  # Broad refusal of executable filter/diff attributes; other attributes remain allowed.
  defp arms_filter_or_diff?(content) do
    Regex.match?(~r/(^|\s)(filter|diff)=\S/m, content)
  end

  # `lstat` finds existing links without following them.
  defp symlink_in_chain?(workspace, rel_path) do
    rel_path
    |> Path.split()
    |> Enum.scan(workspace, fn part, acc -> Path.join(acc, part) end)
    |> Enum.any?(&symlink?/1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp write_validated_files(workspace, files) do
    Enum.reduce_while(files, :ok, fn
      %{"path" => rel_path, "content" => content}, :ok ->
        full_path = Path.join(workspace, rel_path)

        with :ok <- File.mkdir_p(Path.dirname(full_path)),
             :ok <- File.write(full_path, content) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:file_write_failed, rel_path, reason}}}
        end
    end)
  end
end
