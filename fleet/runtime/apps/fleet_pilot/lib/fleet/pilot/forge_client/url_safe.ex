defmodule Fleet.Pilot.ForgeClient.UrlSafe do
  @moduledoc """
  Encodage SÛR des segments d'URL forge, extrait de `ForgeClient.Transport` : le verrou
  path-traversal du client. Cluster PUR (binaire → binaire), zéro config, zéro I/O —
  d'où sa sortie du moteur HTTP (Transport garde la plomberie : config/token, Req,
  pagination, login système).

  ## Pourquoi (sécurité)

  `repo`/`path`/`ref`/`username`/`topic`/`org`/`label_name` viennent du brief (issue/PR), du
  catalogue ou de la config et sont interpolés dans l'URL Gitea. Un segment hostile (`../`, espace,
  `?x=1`, `#frag`) traverserait l'API (`/repos/owner/../admin/...`) ou INJECTERAIT une query/fragment
  qui changerait le sens de la requête. On ENCODE donc chaque segment au plus près de l'interpolation —
  PAS un slug (un `repo` = `owner/name` ET un `path` de fichier contiennent légitimement des `/`), mais
  un encodage qui rend `..`/`/`/espace/`?`/`#` INERTES.

  Deux pièges traités :

    1. un `/` injecté DANS un composant (`name = "x/../admin"`) fabriquerait un faux séparateur →
       `encode_seg` percent-encode le `/` (`%2F`), il ne peut plus séparer.
    2. un composant qui EST le séparateur de chemin `.`/`..` (`repo = "fleet/../admin"`, le `..` est un
       composant entier après split) : `URI.encode_www_form` ne touche PAS le `.` (caractère unreserved),
       donc un `..` brut SURVIVRAIT et le serveur normaliserait le chemin (traversée). On NEUTRALISE
       donc tout composant `.`/`..`/vide en percent-encodant ses points (`..` → `%2E%2E`) → segment
       littéral inerte sur le fil, jamais un opérateur de chemin. C'est le verrou réel du vecteur repo.

  `encode_seg/1` = un composant atomique (username, org, topic, label, ref-en-path) ;
  `encode_repo/1`/`encode_path/1` = multi-composant (`owner/name`, `dir/sub/file`), `/` structurels
  préservés, chaque composant passé par le même verrou. Pour une QUERY (`?ref=…`),
  `URI.encode_www_form` directement (cf. `ForgeClient.get_file`).
  """

  @doc "Encode un composant d'URL atomique (rend `/`, `..`, espace, `?`, `#` inertes)."
  @spec encode_seg(String.t()) :: String.t()
  def encode_seg(seg) when is_binary(seg), do: encode_component(seg)

  @doc """
  Encode un `owner/name` en préservant le `/` structurel mais en neutralisant tout `/`/`..`/composant
  de traversée injecté DANS un composant (owner ou name).
  """
  @spec encode_repo(String.t()) :: String.t()
  def encode_repo(repo) when is_binary(repo) do
    repo |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  @doc """
  Encode un path de fichier multi-segment (`dir/sub/file.md`) : `/` structurels préservés, chaque
  composant neutralisé → un `..`/`.` injecté est inerte, pas de traversée de l'API contents.
  """
  @spec encode_path(String.t()) :: String.t()
  def encode_path(path) when is_binary(path) do
    path |> String.split("/") |> Enum.map_join("/", &encode_component/1)
  end

  # UN composant de chemin sûr. Un composant de TRAVERSÉE (`.`/`..`) est percent-encodé sur ses points
  # (`..` → `%2E%2E`) → segment littéral inerte que le serveur ne normalisera PAS comme un opérateur de
  # chemin (le `.` est unreserved : `URI.encode_www_form` ne le toucherait pas, d'où ce cas dédié — c'est
  # LE verrou du vecteur `owner/../admin`). Un composant vide (`//`) ne traverse pas → laissé tel quel.
  # Tout autre composant passe par `URI.encode_www_form` (le `/` interne devient `%2F`, l'espace `%20`,
  # `?`/`#` encodés). Le `+` (espace www-form) est re-traduit en `%20` (sémantique path-segment, pas form).
  defp encode_component(comp) when comp in [".", ".."] do
    String.replace(comp, ".", "%2E")
  end

  defp encode_component(comp) when is_binary(comp) do
    comp |> URI.encode_www_form() |> String.replace("+", "%20")
  end
end
