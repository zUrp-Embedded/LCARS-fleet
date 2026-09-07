defmodule Fleet.API.BindAddressTest do
  @moduledoc """
  Bind contract of the API domain — 2026-08-14.

  ## Ce que ce fichier epinglait, et pourquoi il ne pouvait pas rester

  Il assertait `ip: {127,0,0,1}` par defaut et le fil de `LCARS_BIND_HOST` jusqu'au listener, pour
  que l'exposition publique reste un opt-in NOMME. Ce contrat n'existe plus : **ce domaine n'a plus
  de listener TCP du tout**. Sa surface de lecture a ete retiree parce qu'elle n'avait aucune
  capacite propre (etats servis par `Fleet.Observation`, `/ws` deja debranche, diagnostics avec un
  jumeau CLI, ecritures sur le socket de controle), et parce que personne ne l'appelait.

  Un test qui continuerait d'asserter l'ancienne forme a cote de la nouvelle epinglerait un contrat
  que plus rien n'honore. La forme est SUBSTITUEE, jamais ajoutee-puis-depreciee : le depot n'a pas
  de prod.

  ## Ce qui remplace, et c'est plus fort

  L'ancien contrat disait « le defaut est sur, et l'elargir est explicite ». Le nouveau dit **il n'y
  a plus rien a elargir** : le dernier test ci-dessous prend le reglage qui pouvait publier cette
  surface sur toutes les interfaces, et montre qu'il ne change plus rien.
  """
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> System.delete_env("LCARS_BIND_HOST") end)
    :ok
  end

  test "aucun listener TCP : sans socket de controle configure, le domaine ne demarre RIEN" do
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.delete_env(:lcars_fleet, :api_control_socket)
    on_exit(fn -> prev && Application.put_env(:lcars_fleet, :api_control_socket, prev) end)

    assert Fleet.API.Application.listener_children() == []
  end

  test "le seul enfant possible est le socket de CONTROLE, et il est AF_UNIX" do
    # L'ecriture (`spawn`) vit la, hors du reseau que le pod partage. C'est la seule surface qui
    # reste a ce domaine — et elle n'a pas d'adresse.
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    assert [child] = Fleet.API.Application.listener_children()
    refute match?({Plug.Cowboy, _}, child)
  end

  test "l'ecriture ne depend plus d'un drapeau nomme d'apres une surface de LECTURE" do
    # `control_socket_child/0` etait imbrique dans `if api_start_listener` : couper la lecture
    # coupait l'ecriture, et le drapeau ne decrivait pas ce qu'il gouvernait. La cle n'existe plus ;
    # ce test refuse qu'elle revienne gouverner le socket de controle.
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")
    Application.put_env(:lcars_fleet, :api_start_listener, false)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :api_start_listener)

      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    assert length(Fleet.API.Application.listener_children()) == 1
  end

  test "LCARS_BIND_HOST n'atteint plus rien — il n'y a plus rien a elargir" do
    # LE TEMOIN DU LOT. C'est le reglage qui publiait cette surface sur toutes les interfaces. Si ce
    # test rougit un jour, une adresse est revenue — et avec elle une origine dont personne ne garde
    # la porte.
    prev = Application.get_env(:lcars_fleet, :api_control_socket)
    Application.put_env(:lcars_fleet, :api_control_socket, "/tmp/lcars-api-bind-test.sock")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:lcars_fleet, :api_control_socket, prev),
        else: Application.delete_env(:lcars_fleet, :api_control_socket)
    end)

    System.delete_env("LCARS_BIND_HOST")
    without = Fleet.API.Application.listener_children()

    System.put_env("LCARS_BIND_HOST", "0.0.0.0")
    assert Fleet.API.Application.listener_children() == without

    # ⚠ L'EGALITE SEULE NE TIENT PAS LA PROMESSE CI-DESSUS. Un enfant ajoute
    # INCONDITIONNELLEMENT — donc present des deux cotes — la laisse vraie : une adresse serait
    # revenue et ce temoin resterait vert, alors que son commentaire promet exactement l'inverse
    # (« si ce test rougit, une adresse est revenue »). L'egalite dit « le reglage n'atteint
    # rien » ; elle ne dit pas « il n'y a rien a elargir ».
    #
    # On epingle donc AUSSI la population : la seule chose que ce superviseur demarre est le socket
    # de controle, un AF_UNIX. Un `Plug.Cowboy` — le seul chemin vers une adresse TCP — n'a rien a
    # y faire, quel que soit l'etat de la variable.
    for enfants <- [without, Fleet.API.Application.listener_children()] do
      assert length(enfants) == 1, "la population des listeners a change : #{inspect(enfants)}"

      refute inspect(enfants) =~ "Cowboy",
             "un listener TCP est revenu dans le superviseur API : #{inspect(enfants)}"
    end
  end
end
