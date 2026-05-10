defmodule Fleet.ClaudeBridge.Stream do
  @moduledoc """
  D4 décidé : écriture maison ~200L (helpers stream events).

  Le SDK `guess/claude_code` expose des helpers `Stream` (660 LOC).
  D4 décide de SKIP ces helpers et écrire les helpers nécessaires
  côté LCARS (~200L) avec intégration native `fleet_event_router`
  (chantier 11) PubSub bus.

  Helpers fournis :

    * `text_content/2` — filtre les events `%{"type" => "text"}`
    * `tool_uses/2` — filtre les events `%{"type" => "tool_use"}`
    * `filter_type/2` — filtre par type arbitraire
    * `until_result/2` — prend les events jusqu'à `%{"type" => "result"}` inclus

  Tous travaillent sur des `Enumerable` (list, lazy stream, etc.) et
  retournent une `list()` matérialisée — ces helpers ne préservent pas
  la lazyness puisque les streams NDJSON consommés sont finis (un turn
  borné par la frame `result`).
  """

  @doc """
  Filtre les events de type `"text"` (message claude texte simple).

  ## Examples

      iex> Fleet.ClaudeBridge.Stream.text_content([%{"type" => "text", "text" => "hello"}, %{"type" => "tool_use"}])
      [%{"type" => "text", "text" => "hello"}]
  """
  @spec text_content(Enumerable.t(), keyword()) :: list()
  def text_content(events, _opts \\ []) do
    Enum.filter(events, &match?(%{"type" => "text"}, &1))
  end

  @doc """
  Filtre les events de type `"tool_use"`.

  ## Examples

      iex> Fleet.ClaudeBridge.Stream.tool_uses([%{"type" => "tool_use", "name" => "Read"}, %{"type" => "text"}])
      [%{"type" => "tool_use", "name" => "Read"}]
  """
  @spec tool_uses(Enumerable.t(), keyword()) :: list()
  def tool_uses(events, _opts \\ []) do
    Enum.filter(events, &match?(%{"type" => "tool_use"}, &1))
  end

  @doc """
  Filtre les events par type arbitraire (string).

  ## Examples

      iex> Fleet.ClaudeBridge.Stream.filter_type([%{"type" => "init"}, %{"type" => "text"}], "init")
      [%{"type" => "init"}]
  """
  @spec filter_type(Enumerable.t(), String.t()) :: list()
  def filter_type(events, type) when is_binary(type) do
    Enum.filter(events, &match?(%{"type" => ^type}, &1))
  end

  @doc """
  Prend les events jusqu'à `%{"type" => "result"}` inclus.

  Utile pour drainer un stream NDJSON jusqu'à la frame finale d'un
  turn. Si pas de frame `result` rencontrée, retourne tous les events.

  ## Examples

      iex> Fleet.ClaudeBridge.Stream.until_result([
      ...>   %{"type" => "init"},
      ...>   %{"type" => "text"},
      ...>   %{"type" => "result"},
      ...>   %{"type" => "extra"}
      ...> ])
      [%{"type" => "init"}, %{"type" => "text"}, %{"type" => "result"}]
  """
  @spec until_result(Enumerable.t(), keyword()) :: list()
  def until_result(events, _opts \\ []) do
    {pre, post} =
      Enum.split_while(events, fn event ->
        not match?(%{"type" => "result"}, event)
      end)

    case post do
      [first | _] -> pre ++ [first]
      [] -> pre
    end
  end
end
