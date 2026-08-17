defmodule Fleet.ReleaseDoorTest do
  @moduledoc """
  `claim_stdout!/0` — la sortie d'une porte release est un format de fil, pas une console.

  Ce que ce temoin tient : la porte DEPLACE le handler, elle ne le coupe pas. Les deux fautes
  possibles sont symetriques et toutes les deux couteuses — laisser le logger sur stdout rend des
  lignes que l'appelant lira comme des donnees (mesure du 2026-08-17 : un `apply` reussi rendu en
  echec) ; le supprimer rend muette la seule trace utile quand la porte echoue.
  """
  # ⚠ `async: false` OBLIGATOIRE, et pour la regle que ce lot vient d'ecrire ailleurs : ce fichier
  # mute le handler `:default`, qui est global au node. Un test concurrent qui loggue pendant la
  # fenetre ecrirait sur stderr sans le savoir.
  use ExUnit.Case, async: false

  setup do
    {:ok, before} = :logger.get_handler_config(:default)

    on_exit(fn ->
      :logger.remove_handler(:default)
      :logger.add_handler(:default, before.module, before)
    end)

    {:ok, before: before}
  end

  test "le handler passe sur stderr — deplace, pas supprime", %{before: before} do
    assert before.config.type == :standard_io

    assert :ok = Fleet.ReleaseDoor.claim_stdout!()

    assert {:ok, after_} = :logger.get_handler_config(:default)
    assert after_.config.type == :standard_error

    # LE HANDLER EST TOUJOURS LA. Le supprimer aurait aussi « libere » stdout, et c'est le remede
    # qui coute le plus cher : une porte qui echoue sans dire pourquoi.
    assert :default in :logger.get_handler_ids()
  end

  test "tout le reste de la configuration survit — meme module, meme niveau, meme format", %{
    before: before
  } do
    # ⚠ CE N'EST PAS UN DETAIL DE PRUDENCE. `type` est immuable sur un handler vivant
    # (`update_handler_config` rend `{:illegal_config_change, …}`), donc la seule voie est de
    # retirer puis reposer — c'est-a-dire de RECONSTRUIRE la configuration. Une reconstruction
    # approximative rendrait au passage le niveau ou le format par defaut, et l'operateur perdrait
    # le reglage qu'il a pose, sans qu'aucun message ne le dise.
    :ok = Fleet.ReleaseDoor.claim_stdout!()
    {:ok, after_} = :logger.get_handler_config(:default)

    # Le formateur vit a la RACINE du handler, pas sous `:config` — deux niveaux, et seul le second
    # porte `type`. C'est exactement l'endroit ou une reconstruction a la main se trompe.
    assert after_.module == before.module
    assert after_.level == before.level
    assert after_.formatter == before.formatter
    assert Map.delete(after_.config, :type) == Map.delete(before.config, :type)
  end
end
