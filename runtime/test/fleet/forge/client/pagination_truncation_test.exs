defmodule Fleet.Forge.Client.PaginationTruncationTest do
  @moduledoc """
  MESURE, pas contrat : ce que `Transport.paginate/4` fait d'une page vide PREMATUREE.

  Son `@moduledoc` annonce « stops on an empty page […] does not reject premature emptiness ».
  Ce fichier le met en chiffres, parce qu'un consommateur en depend pour EFFACER : le convergeur des
  catalogues retire le materiel local de tout catalogue absent de la liste rendue.

  ⚠ LE DEFAUT EXISTE, ET GITEA NE PRODUIT PAS L'ENTREE QUI LE DECLENCHE. Mesure du 2026-09-20, sur
  une Gitea jetable portant 121 branches, interrogee exactement comme `paginate/4` le fait
  (`?page=N&limit=50`) :

      page=1  objets=50  X-Total-Count=121
      page=2  objets=50  X-Total-Count=121
      page=3  objets=21  X-Total-Count=121
      page=4  objets=0   X-Total-Count=121

  Gitea REMPLIT ses pages jusqu'a epuisement et ne rend une page vide qu'APRES la fin, avec un total
  correct et stable. `paginate/4` s'arrete donc sur `121 >= 121` a la page 3 : la page vide n'est
  jamais demandee. Une page vide PREMATUREE demanderait une suppression massive de branches PENDANT
  la pagination, sur un magasin qui porte deja plus de cinquante catalogues — en deca, il n'y a
  qu'une seule page et aucune seconde requete.

  Ce temoin reste parce que la PROPRIETE reste : si quelqu'un se met un jour a compter sur
  « paginate refuse une liste tronquee », cette ligne dit que non.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.Client.Transport

  # Un serveur qui annonce 120 objets, en sert 50, puis rend une page VIDE. La forme exacte qu'un
  # serveur produit quand des objets disparaissent entre deux pages.
  defmodule TronqueApresUnePage do
    @behaviour Plug

    @impl Plug
    def init(o), do: o

    @impl Plug
    def call(conn, _o) do
      conn = Plug.Conn.fetch_query_params(conn)
      page = conn.query_params["page"]

      corps =
        case page do
          "1" -> for i <- 1..50, do: %{"name" => "branche-#{i}"}
          _ -> []
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("x-total-count", "120")
      |> Plug.Conn.send_resp(200, JSON.encode!(corps))
    end
  end

  test "une page vide PREMATUREE rend {:ok, liste courte} — pas une erreur" do
    config = %{
      base_url: "http://fake.test",
      token: "t",
      anonymous: false,
      req_options: [plug: {TronqueApresUnePage, []}]
    }

    resultat = Transport.paginate(config, "/repos/o/r/branches", "", nil)

    assert {:ok, liste} = resultat,
           "si paginate REFUSAIT une liste tronquee, ce serait {:error, _} et le sujet serait clos"

    assert length(liste) == 50,
           "le serveur a annonce 120 objets et en a servi 50 : la liste rendue en porte #{length(liste)}"
  end
end
