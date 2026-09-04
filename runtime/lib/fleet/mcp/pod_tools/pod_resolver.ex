defmodule Fleet.MCP.PodTools.PodResolver do
  @moduledoc """
  La couture « identite d'un pod » : UNE clef, UN defaut, UN contrat.

  `Delegation` et `Probe` posent la meme question — a quel role et a quel depot ce pod est-il lie —
  et la reponse doit etre la meme. Le commentaire de `Probe` l'ecrivait deja : « deux resolveurs de
  la meme identite de canal donneraient deux avis sur *a quel depot ce pod est lie* ».

  ⚠ UNE SEULE FONCTION DE REPLI, ICI. Deux copies du defaut chez les deux lecteurs, sous une meme
  clef (`:mcp_pod_resolver`), laisseraient l'une repondre a l'ancienne facon quand l'autre change,
  EN SILENCE, puisque le defaut ne s'exerce que lorsque la configuration est absente : jamais en
  test, toujours en production.

  Meme forme que `Delegation.ForgeClient` : le module qui declare le contrat est celui qui porte le
  defaut, et les appelants ne connaissent que `resolved/0`.
  """

  @typedoc """
  L'identite d'un pod telle que ses consommateurs la lisent.

  ⚠ CE TYPE EST PLUS PRECIS QUE SA SOURCE, ET C'EST VOULU. `Fleet.Spawner.pod_info/1` declare
  `{:ok, map()}` — un des retours creux du depot : present, donc conforme au mur `@spec`, et sans
  information pour dialyzer. Les clefs ci-dessous sont celles dont les appelants de cette couture
  DEPENDENT reellement ; les enumerer ici est ce qui donne prise a `:pattern_match`.

  ⚠ `:repo_id` EST DANS LE TYPE, et il y reste : sans lui dialyzer declare inatteignable la clause
  de `Probe.identity/2` qui traduit un identifiant numerique en nom complet via la forge — le cas
  des roles dont le pod porte `repo_id` et pas `repo`. Les deux consommateurs de cette couture
  n'attendent PAS la meme forme : `Delegation` lit `:role`/`:repo`, `Probe` lit `:repo`/`:repo_id`.
  """
  @type identity :: %{
          optional(:role) => String.t(),
          optional(:repo) => String.t() | nil,
          optional(:repo_id) => pos_integer() | nil
        }

  @doc """
  Le contrat que doit tenir toute implantation injectee.

  Declare, la ou il n'y avait qu'une fonction nue : un test pouvait injecter n'importe quoi, et
  seule la forme du `case` cote appelant disait ce qui etait attendu.
  """
  @callback resolve(pod_id :: String.t()) :: {:ok, identity()} | {:error, term()}

  @doc false
  @spec resolved() :: (String.t() -> {:ok, identity()} | {:error, term()})
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_pod_resolver, &__MODULE__.default/1)

  # `rescue`/`catch` : le spawner peut etre absent (banc MCP seul) ou en cours de redemarrage. Une
  # identite inconnue est un REFUS, jamais une exception qui remonte dans l'outil MCP.
  @doc false
  @spec default(String.t()) :: {:ok, identity()} | {:error, term()}
  def default(pod_id) when is_binary(pod_id) do
    Fleet.Spawner.pod_info(pod_id)
  rescue
    _ -> {:error, :pod_unknown}
  catch
    _, _ -> {:error, :pod_unknown}
  end

  def default(_pod_id), do: {:error, :pod_unknown}
end
