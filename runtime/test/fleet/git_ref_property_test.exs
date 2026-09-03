defmodule Fleet.GitRefPropertyTest do
  @moduledoc """
  Property-based proof of the ref validation primitive. `git_ref_test.exs` pins named cases;
  here we prove the direction that MATTERS — the FALSE-ACCEPT.

  The module exists to prevent a malformed name from reaching a real `git clone`/`push`/`commit`.
  A false-REJECT is benign (we refuse a ref git would have taken: the clone does not start,
  it's noisy). A false-ACCEPT is the failure: the ref goes to git, which refuses it deep in the
  pipe, or worse interprets it (cf. the #39 scar — `"main\\n"` declared valid by `^…$` anchors).
  The property's oracle is therefore `git` ITSELF: whatever `valid?` accepts,
  `git check-ref-format --branch` must accept.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.GitRef

  # ── generators ──

  # Healthy component: the charset `@ref_re` allows between the `/`.
  defp component do
    string([?a..?z, ?A..?Z, ?0..?9, ?., ?_, ?-], min_length: 1, max_length: 6)
  end

  # The poisons: exactly the classes `check-ref-format` refuses and that a charset regex
  # alone would miss (`..`, `.lock`, trailing `.`, empty component), plus the control-chars/
  # spaces the charset MUST exclude, plus the refspec meta-characters (`~^:?*[\`, `@{`).
  defp poison do
    member_of([
      "..",
      ".lock",
      ".",
      "/",
      "//",
      "\n",
      "\r",
      "\t",
      "\0",
      " ",
      "-",
      "@{",
      "~",
      "^",
      ":",
      "?",
      "*",
      "[",
      "\\"
    ])
  end

  # Generated ref: 1 to 3 healthy components, with (often) a poison injected at an arbitrary
  # position — head, middle or tail. HEALTHY refs (no poison) are in the draw: the differential
  # property must also prove we don't over-tighten down to nothing.
  defp ref_gen do
    gen all(
          comps <- list_of(component(), min_length: 1, max_length: 3),
          p <- one_of([constant(nil), poison()]),
          pos <- integer(0..30)
        ) do
      base = Enum.join(comps, "/")

      case p do
        nil ->
          base

        p ->
          {head, tail} = String.split_at(base, min(pos, String.length(base)))
          head <> p <> tail
      end
    end
  end

  # ── P2 — PURE (the invariant with no external dependency) ──

  # INVARIANT: any string carrying `..`, a space or a control-char is REFUSED, wherever the
  # poison sits (including in terminal position).
  # WHY: `..` is the traversal (`refs/heads/../../evil`), space and control-chars are what
  # breaks refspec parsing on git's side. The TERMINAL position is the #39 scar:
  # with `^…$` anchors, `"main\n"` passed. This property locks it for ANY prefix.
  property "P2 PURE — `..`, space or control-char anywhere ⇒ valid? == false" do
    check all(
            prefix <- string([?a..?z, ?0..?9], max_length: 6),
            bad <- member_of(["..", " ", "\n", "\r", "\t", "\0", "\v", "\f"]),
            suffix <- string([?a..?z, ?0..?9], max_length: 6)
          ) do
      candidate = prefix <> bad <> suffix

      refute GitRef.valid?(candidate),
             "ref #{inspect(candidate)} must be refused (traversal / control-char)"
    end
  end

  # ── P1 — DIFFERENTIAL (oracle = git) ──
  #
  # ⚠ Depends on the `git` binary (:external tag). If git is absent from the environment, the
  # property is replaced by an explicit skipped test — never a silent green on a missing oracle.
  #
  # ⚠ FALSE POSITIVE RULED OUT — flagging `valid?("HEAD") == true` as a false-accept (because
  # `git check-ref-format --branch HEAD` fails) is wrong: "fixing" it breaks 12 tests
  # (Deliverable). `"HEAD"` is LOAD-BEARING — it is the LOCAL side of every deliverable push
  # (`git push <remote> HEAD:refs/heads/<branch>`, `Deliverable.local_ref/1` by default). The
  # `--branch` oracle answers "can a branch of this name be CREATED?"; the module's contract is
  # "is this a well-formed git ref?". Two different questions: the gap is a DELIBERATE choice,
  # not a defect. `HEAD` is therefore knowingly EXCLUDED from the differential below, rather
  # than silently masked.
  @branch_oracle_exceptions ["HEAD"]

  test "`HEAD` stays a VALID ref (local side of the deliverable push) — the --branch oracle does not apply" do
    assert GitRef.valid?("HEAD")
  end

  # INVARIANT: valid?(ref) ⟹ `git check-ref-format --branch ref` exits 0.
  # WHY: `valid?` CLAIMS to carry "the full git authority" (R2-06), not a "roughly
  # aligned". Any ref we let through that git refuses is a `clone`/`push` failing deep
  # down, far from the input point, with an opaque git message instead of the typed
  # `{:invalid_ref, ref}` the callers know how to handle.
  #
  # The `git` prerequisite is resolved STRUCTURALLY (test_helper excludes :requires_git at run time
  # when the binary is absent), never by a compile-time branch onto a hollow test: the machine's
  # verdict belongs in the bilan's exclusions, not disguised as a green about the code.
  @tag :external
  @tag :requires_git
  property "P1 DIFFERENTIAL — valid?(ref) ⟹ git check-ref-format --branch accepts it" do
    check all(ref <- ref_gen(), max_runs: 300) do
      if GitRef.valid?(ref) and ref not in @branch_oracle_exceptions do
        assert git_accepts_branch?(ref),
               "valid?(#{inspect(ref)}) == true but git check-ref-format --branch REFUSES it " <>
                 "— false-accept: the ref would reach a real clone/push"
      end
    end
  end

  # `git` is called ONLY on refs `valid?` accepted: they are thus guaranteed free of NUL
  # (which System.cmd would refuse) and of a leading `-` (which git would take as an option).
  defp git_accepts_branch?(ref) do
    {_out, code} =
      System.cmd("git", ["check-ref-format", "--branch", ref],
        stderr_to_stdout: true,
        cd: System.tmp_dir!()
      )

    code == 0
  end
end
