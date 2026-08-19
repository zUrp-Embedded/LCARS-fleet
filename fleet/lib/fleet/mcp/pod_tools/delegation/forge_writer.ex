defmodule Fleet.MCP.PodTools.Delegation.ForgeWriter do
  @moduledoc """
  La surface qui écrit du CONTENU sur la forge — branche, fichier, pull request.

  ## Pourquoi elle n'est PAS dans `ForgeClient`

  `ForgeClient` porte l'état des TICKETS : poser un label, commenter, fermer, lire un jury. Son
  effet est visible sur la forge et nulle part ailleurs. Ces trois-ci fabriquent un **diff qu'un
  humain va signer**, et ce que ce diff dit devient ce que root applique. Deux natures, deux
  contrats.

  Le motif est aussi mécanique, et il aurait suffi à lui seul : `Delegation.conforming/2` exige
  qu'une implémentation exporte **tous** les callbacks de son behaviour. Six doublures de test
  implémentent `ForgeClient` ; y ajouter trois callbacks les aurait toutes rendues non conformes
  d'un coup, pour un chemin qu'aucune n'emprunte. Un contrat séparé n'oblige à écrire une doublure
  qu'à ce qui s'en sert.

  ⚠ **Aucun pod n'appelle ceci.** Le pod tape des champs typés dans son outil MCP ; c'est le
  RUNTIME qui rend le manifeste et l'écrit. La séparation est le fond du rail : ce qu'un humain
  approuve est un document que le système a composé, jamais de la prose qu'un pod a rédigée.
  """

  @doc """
  Crée une branche depuis une référence existante.

  Site d'appel : la demande d'outillage — la branche de demande, sur laquelle le manifeste est
  écrit avant d'être proposé. Rien n'atterrit sur la branche protégée avant le merge : un lecteur
  (le convergeur, un bug futur) ne doit jamais pouvoir trouver une déclaration non validée.
  """
  @callback create_branch(
              repo :: String.t(),
              branch :: String.t(),
              old_ref :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Écrit (ou remplace) un fichier sur une branche.

  UN FICHIER PAR ÉCOSYSTÈME, jamais un par demande : deux pods qui demandent python convergent sur
  le même document plutôt que d'accumuler un fichier chacun. Le second remplace ce que le premier a
  déclaré, et le diff montre à un humain ce qui change réellement.
  """
  @callback put_file(
              repo :: String.t(),
              path :: String.t(),
              content :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @doc """
  Ouvre une pull request.

  C'EST LA GARDE, pas une notification. Et rien ne s'installe au merge non plus : le réconciliateur
  voit la branche bouger et le convergeur applique. Trois acteurs, et le seul qui tourne en root
  prend un manifeste qu'un humain a déjà approuvé.
  """
  @callback open_pr(
              repo :: String.t(),
              head :: String.t(),
              base :: String.t(),
              title :: String.t(),
              opts :: keyword()
            ) :: {:ok, term()} | {:error, term()}

  @default_writer Fleet.Forge.Client

  @doc """
  L'implémentation configurée, ou le client canonique.

  MÊME CLEF que `ForgeClient.resolved/0` (`:lcars_fleet, :mcp_forge_client`) — le seam est le MÊME
  objet, seul le contrat qu'on lui demande de tenir diffère. Deux clefs pour un client seraient deux
  façons de brancher un test sur des moitiés différentes de la même forge, et un test qui remplace
  l'une sans l'autre verrait ses écritures partir sur la vraie.
  """
  @spec resolved() :: module()
  def resolved, do: Application.get_env(:lcars_fleet, :mcp_forge_client, @default_writer)
end
