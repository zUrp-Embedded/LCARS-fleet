defmodule Fleet.ClaudeBridge.HookRegistryTest do
  use ExUnit.Case, async: true

  alias Fleet.ClaudeBridge.HookRegistry

  doctest Fleet.ClaudeBridge.HookRegistry

  describe "build!/1 — F-ADP-2 conformance CRITICAL" do
    test "raise quand permission_adapter manquant des opts" do
      assert_raise RuntimeError, ~r/F-ADP-2.*permission_adapter obligatoire/, fn ->
        HookRegistry.build!([])
      end
    end

    test "raise quand permission_adapter explicitement nil" do
      assert_raise RuntimeError, ~r/F-ADP-2.*permission_adapter obligatoire/, fn ->
        HookRegistry.build!(permission_adapter: nil)
      end
    end

    test "retourne map avec can_use_tool non-nil pour adapter valide" do
      assert %{can_use_tool: SomeModule, hooks_pre: [], hooks_post: []} =
               HookRegistry.build!(permission_adapter: SomeModule)
    end

    test "défaut hooks_pre et hooks_post à liste vide" do
      assert %{hooks_pre: [], hooks_post: []} =
               HookRegistry.build!(permission_adapter: SomeModule)
    end

    test "passe hooks_pre et hooks_post fournis tels quels" do
      pre = [{:pre_tool_use, ModA}]
      post = [{:post_tool_use, ModB}]

      assert %{hooks_pre: ^pre, hooks_post: ^post} =
               HookRegistry.build!(
                 permission_adapter: SomeModule,
                 hooks_pre: pre,
                 hooks_post: post
               )
    end
  end

  describe "validate!/1 — guard runtime sur registry pré-construit" do
    test "raise quand can_use_tool nil" do
      assert_raise RuntimeError, ~r/F-ADP-2.*can_use_tool nil interdit/, fn ->
        HookRegistry.validate!(%{can_use_tool: nil, hooks_pre: [], hooks_post: []})
      end
    end

    test ":ok quand can_use_tool est un module atom non-nil" do
      assert :ok =
               HookRegistry.validate!(%{
                 can_use_tool: SomeModule,
                 hooks_pre: [],
                 hooks_post: []
               })
    end

    test "raise sur shape map invalide (pas de can_use_tool)" do
      assert_raise RuntimeError, ~r/F-ADP-2.*shape invalide/, fn ->
        HookRegistry.validate!(%{hooks_pre: [], hooks_post: []})
      end
    end
  end
end
