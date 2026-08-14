defmodule Mix.Tasks.Lcars.Contracts.ToolsGatedCheckTest do
  @moduledoc """
  The `mcp.tools_gated` wall, proven against CRAFTED trees — because it reports absences.

  A check that only ever runs on a clean repo cannot tell "nothing is wrong" from "nothing was
  measured". Three of the day's thirteen defects were carried by the instrument, not the subject.
  So every refusal this wall is supposed to make is exercised here on a fixture, and each is paired
  with the inverse case where it must stay silent.

  What it guards: `tools/list` is discovery, `tools/call` re-verifies nothing against it. A
  `deftool` wired to an ungated body is callable by any pod, and a `handle_tool_call` with no
  `deftool` is callable while absent from every catalogue.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  @tools_rel "lib/fleet/mcp/pod_tools.ex"
  @deleg_rel "lib/fleet/mcp/pod_tools/delegation.ex"

  # A delegation module with 10 gated functions (the instrument floor) plus whatever the caller adds.
  defp delegation(extra \\ "") do
    gated =
      Enum.map_join(1..10, "\n", fn i ->
        """
          def gated_#{i}(state) do
            with {:ok, %{repo: repo}} <- require_architect(state), do: {:ok, repo}
          end
        """
      end)

    """
    defmodule Delegation do
    #{gated}
    #{extra}
    end
    """
  end

  # 12 tools (the instrument floor), all routed to gated delegations, plus whatever the caller adds.
  defp pod_tools(extra_tools \\ "", extra_clauses \\ "") do
    tools = Enum.map_join(1..12, "\n", &"  deftool \"t#{&1}\" do\n    :schema\n  end\n")

    clauses =
      Enum.map_join(1..12, "\n", fn i ->
        """
          def handle_tool_call("t#{i}", _args, state) do
            Delegation.gated_#{min(i, 10)}(state)
          end
        """
      end)

    """
    defmodule PodTools do
    #{tools}
    #{extra_tools}
    #{clauses}
    #{extra_clauses}
    end
    """
  end

  defp tree(tools_src, deleg_src) do
    root = Path.join(System.tmp_dir!(), "tools_gated_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/fleet/mcp/pod_tools"))
    File.write!(Path.join(root, @tools_rel), tools_src)
    File.write!(Path.join(root, @deleg_rel), deleg_src)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(tools_src, deleg_src), do: Check.check_mcp_tools_gated(tree(tools_src, deleg_src))

  describe "the instrument answers for itself first" do
    test "a tree it cannot parse into tools FAILS as broken — it never passes by measuring nothing" do
      result = check("defmodule PodTools do\nend\n", delegation())

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "a delegation whose gates all vanished is broken, not compliant" do
      result = check(pod_tools(), "defmodule Delegation do\nend\n")

      assert result.status == :fail
      assert hd(result.evidence) =~ "INSTRUMENT BROKEN"
    end

    test "INVERSE TWIN — a well-formed tree is not called broken" do
      result = check(pod_tools(), delegation())

      assert result.status == :pass
      refute Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end
  end

  describe "a tool with no gate" do
    test "an 18th deftool wired to an ungated body is REFUSED and named" do
      result =
        check(
          pod_tools(
            "  deftool \"nuke\" do\n    :schema\n  end\n",
            "  def handle_tool_call(\"nuke\", _args, state) do\n    Delegation.ungated(state)\n  end\n"
          ),
          delegation("  def ungated(state), do: {:ok, state}\n")
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "ungated tools"
      assert hd(result.evidence) =~ "nuke"
    end

    test "a COMMENT naming require_architect does not gate anything — the AST has no comments" do
      result =
        check(
          pod_tools(
            "  deftool \"nuke\" do\n    :schema\n  end\n",
            "  def handle_tool_call(\"nuke\", _args, state) do\n    Delegation.ungated(state)\n  end\n"
          ),
          delegation("""
            # gated by require_architect(state) upstream, trust me
            def ungated(state), do: {:ok, state}
          """)
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "nuke"
    end

    test "a tool made ONLY of refusals is not gated by its own emptiness" do
      result =
        check(
          pod_tools(
            "  deftool \"hollow\" do\n    :schema\n  end\n",
            "  def handle_tool_call(\"hollow\", _args, state) do\n    {:error, :invalid_arguments, state}\n  end\n"
          ),
          delegation()
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "hollow"
    end

    test "INVERSE TWIN — pod-scoped identity gates without any Delegation call" do
      result =
        check(
          pod_tools(
            "  deftool \"mine\" do\n    :schema\n  end\n",
            """
              def handle_tool_call("mine", _args, %{pod_id: pod_id} = state)
                  when is_binary(pod_id) do
                {:ok, pod_id, state}
              end

              def handle_tool_call("mine", _args, state) do
                {:error, :pod_id_required, state}
              end
            """
          ),
          delegation()
        )

      assert result.status == :pass
    end
  end

  # JG-134 — RECEVOIR L'IDENTITE N'EST PAS S'EN SERVIR. `PodSocketAcceptor` construit
  # `%{pod_id: pod_id}` pour CHAQUE `tools/call`, a l'identique et sans condition : la presence de
  # cette cle dans une tete de clause ne dit donc rien de l'autorisation. Le predicat cherchait
  # `\bpod_id:` et acceptait `%{pod_id: _}` — une clause qui filtre l'identite, la jette, puis agit
  # globalement etait rapportee comme gardee. Le mur faisait la largeur d'un underscore.
  #
  # Mesure avant de resserrer, parce qu'un mur ne peut naitre que vert : 23 des 25 outils sont
  # ROLE-gardes (`require_architect`/`require_onboarder`), tous les mutateurs parmi eux, et les deux
  # seuls admis par ce predicat sont `get_work_item` et `submit_result` — qui lient et qui
  # utilisent. Le trou etait reel et personne ne se tenait dedans.
  describe "pod-scoped — la clause doit LIER l'identite du canal et s'en servir" do
    defp scoped_tool(head_state, body) do
      check(
        pod_tools(
          "  deftool \"mine\" do\n    :schema\n  end\n",
          """
            def handle_tool_call("mine", _args, #{head_state}) do
              #{body}
            end
          """
        ),
        delegation()
      )
    end

    test "identite JETEE (`%{pod_id: _}`) → REFUSE : le motif est fourni a tous les outils" do
      result = scoped_tool("%{pod_id: _}", "{:ok, :everything, %{}}")

      assert result.status == :fail,
             "une clause qui jette l'identite du canal a ete rapportee comme gardee"

      assert hd(result.evidence) =~ "mine"
    end

    test "identite LIEE mais jamais utilisee → REFUSE : le sujet ne vient pas du canal" do
      result = scoped_tool("%{pod_id: pod_id} = state", "{:ok, :everything, state}")

      assert result.status == :fail
      assert hd(result.evidence) =~ "mine"
    end

    test "un discard nomme (`_pod_id`) ne passe pas non plus — c'est le meme aveu" do
      result = scoped_tool("%{pod_id: _pod_id} = state", "{:ok, :everything, state}")

      assert result.status == :fail
      assert hd(result.evidence) =~ "mine"
    end

    test "INVERSE TWIN — liee ET utilisee, meme au fond du corps → pass" do
      result =
        scoped_tool(
          "%{pod_id: pod_id} = state",
          "with {:ok, item} <- WorkItems.fetch(pod_id), do: {:ok, item, state}"
        )

      assert result.status == :pass, "evidence: #{inspect(result.evidence)}"
    end
  end

  describe "the inverse twin — dispatched without a catalogue entry" do
    test "a handle_tool_call with no deftool is REFUSED: absent from tools/list, live on tools/call" do
      result =
        check(
          pod_tools(
            "",
            "  def handle_tool_call(\"ghost\", _args, state) do\n    Delegation.gated_1(state)\n  end\n"
          ),
          delegation()
        )

      assert result.status == :fail
      assert hd(result.evidence) =~ "without a deftool"
      assert hd(result.evidence) =~ "ghost"
    end

    test "the catch-all clause is not mistaken for a ghost tool — it has no literal name" do
      result =
        check(
          pod_tools(
            "",
            "  def handle_tool_call(_unknown, _args, state) do\n    {:error, :unknown_tool, state}\n  end\n"
          ),
          delegation()
        )

      assert result.status == :pass
    end
  end

  describe "against the real tree" do
    test "the repo passes, and the note says what was actually measured" do
      result = Check.check_mcp_tools_gated(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "tools, each pod-scoped or role-gated"
    end
  end
end
