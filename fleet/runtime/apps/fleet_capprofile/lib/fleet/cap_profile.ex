defmodule Fleet.CapProfile do
  @moduledoc """
  Capability Profile composer/loader/validator (LCARS schema v2.5).

  Pure data transformer: YAML on disk → composed `%Fleet.CapProfile{}`
  struct. No process, no state. Three public functions (`load/1`,
  `compose/2`, `validate/1`) implementing the `Fleet.CapProfile.Loader`
  behaviour.

  Schema is pinned to `apiVersion: lcars/v2.5`. Every profile is matched
  against `priv/schema/cap-profile-v2.5.json` at load time. Modops are
  matched against `priv/schema/modop-profile.json` (strict — reserved
  keys forbidden, mitigates the "containment override by modop" finding
  from PoC-11).

  Composition is deterministic: deep-merge last-wins in declared order,
  canonical JSON encoding (recursive key sort), `:crypto` sha256.
  """

  @behaviour Fleet.CapProfile.Loader

  require Logger

  defstruct [:api_version, :kind, :metadata, :spec]

  @type t :: %__MODULE__{
          api_version: String.t(),
          kind: String.t(),
          metadata: map(),
          spec: map()
        }

  @api_version_pinned "lcars/v2.5"
  @kind_pinned "CapabilityProfile"

  # G24-9 (F-CONT-RISK) — server tools natifs Anthropic must be denied.
  # Strict entries match by equality, prefix entries by `String.starts_with?/2`.
  @disallowed_minimum_strict ~w(web_search web_fetch code_execution bash_code_execution text_editor_code_execution)
  @disallowed_minimum_prefix ~w(tool_search_)

  @containment_enum ~w(bwrap none)
  @lifetime_scope_enum ~w(one-shot pipe run session-user forever)

  # Fast-path guard for top-level reserved keys. `metadata.containment`
  # and `metadata.name` are also reserved — enforced by the JSON schema
  # `priv/schema/modop-profile.json` (`not/anyOf` clause).
  @reserved_modop_keys ~w(apiVersion kind)

  # ============================================================
  # Loader behaviour
  # ============================================================

  @doc """
  Charge un cap-profile YAML pour le rôle donné, valide contre le schema
  `priv/schema/cap-profile-v2.5.json`.

  Path resolution : `<root_dir>/<role>.yaml` puis fallback
  `<root_dir>/archivistes/<role>.yaml` (cohérence v1.5).

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — chargement et validation OK
    * `{:error, :not_found}` — fichier YAML absent
    * `{:error, :invalid_schema}` — YAML mal formé OU non-conforme au schema
    * `{:error, :schema_unavailable}` — fichier schema priv absent ou corrompu
  """
  @impl Fleet.CapProfile.Loader
  @spec load(String.t()) :: {:ok, t()} | {:error, atom() | String.t()}
  def load(role) when is_binary(role) do
    with {:ok, raw} <- read_role_yaml(role),
         :ok <- validate_against_schema(raw, :cap_profile) do
      {:ok, to_struct(raw)}
    end
  end

  @doc """
  Compose un cap-profile à partir d'un rôle de base et d'une liste ordonnée
  de modops. Deep-merge last-wins, ordre déclaré = précédence (PoC-16).

  Le résultat est revalidé contre le schema cap-profile post-merge.

  ## Exit codes
    * `{:ok, %Fleet.CapProfile{}}` — composition OK
    * `{:error, :not_found}` — rôle de base absent
    * `{:error, :modop_not_found}` — au moins un modop nommé est absent
      (le nom du modop manquant est loggé via `Logger.warning/1`)
    * `{:error, :invalid_schema}` — base ou résultat post-merge non-conforme
    * `{:error, :invalid_modop}` — modop YAML invalide ou clés réservées
    * `{:error, :schema_unavailable}` — fichier schema priv absent ou corrompu
  """
  @impl Fleet.CapProfile.Loader
  @spec compose(String.t(), [String.t()]) :: {:ok, t()} | {:error, term()}
  def compose(role, modop_set) when is_binary(role) and is_list(modop_set) do
    with {:ok, base} <- read_role_yaml(role),
         :ok <- validate_against_schema(base, :cap_profile),
         {:ok, modops} <- read_modops(modop_set),
         merged <- Enum.reduce(modops, base, &deep_merge_last_wins(&2, &1)),
         :ok <- validate_against_schema(merged, :cap_profile) do
      {:ok, to_struct(merged)}
    end
  end

  @doc """
  Valide un `%Fleet.CapProfile{}` contre les 9 invariants G24 (canon
  cap-profile v2.5 + F-CONT-RISK gate).

  ## Exit codes
    * `:ok` — tous les invariants passent
    * `{:error, [violation_codes]}` — liste des invariants violés, atomes
      parmi `:g24_1`..`:g24_8`, `:g24_9_strict`, `:g24_9_prefix`
  """
  @impl Fleet.CapProfile.Loader
  @spec validate(t()) :: :ok | {:error, [atom()]}
  def validate(%__MODULE__{} = profile) do
    violations =
      [
        {:g24_1, &check_containment/1},
        {:g24_2, &check_api_version/1},
        {:g24_3, &check_kind/1},
        {:g24_4, &check_lifetime_scope/1},
        {:g24_5, &check_git_ops_denied/1},
        {:g24_6, &check_modop_incompatible/1},
        {:g24_7, &check_budget/1},
        {:g24_8, &check_metadata_name/1},
        {:g24_9_strict, &check_disallowed_strict/1},
        {:g24_9_prefix, &check_disallowed_prefix/1}
      ]
      |> Enum.reject(fn {_code, fun} -> fun.(profile) == :ok end)
      |> Enum.map(fn {code, _fun} -> code end)

    case violations do
      [] -> :ok
      list -> {:error, list}
    end
  end

  # ============================================================
  # Public helpers
  # ============================================================

  @doc """
  Returns the canonical JSON sha256 (lowercase hex) of a composed map
  or struct. Used by callers to assert deterministic composition
  (PoC-16 pattern). Underlying map iteration order is irrelevant — the
  canonical encoder sorts keys recursively before encoding.
  """
  @spec sha256(t() | map()) :: String.t()
  def sha256(%__MODULE__{} = profile), do: profile |> struct_to_map() |> sha256()

  def sha256(map) when is_map(map) do
    map
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ============================================================
  # I/O
  # ============================================================

  defp read_role_yaml(role) do
    candidates = [
      Path.join(root_dir(), "#{role}.yaml"),
      Path.join([root_dir(), "archivistes", "#{role}.yaml"])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> decode_yaml(path)
    end
  end

  defp read_modops(modop_set) do
    result =
      Enum.reduce_while(modop_set, {:ok, []}, fn name, {:ok, acc} ->
        path = Path.join([root_dir(), "modop", name, "profile.yaml"])

        if File.exists?(path) do
          with {:ok, raw} <- decode_yaml(path),
               :ok <- validate_modop_keys(raw),
               :ok <- validate_against_schema(raw, :modop) do
            {:cont, {:ok, [raw | acc]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          Logger.warning("modop not found: #{inspect(name)} at #{path}")
          {:halt, {:error, :modop_not_found}}
        end
      end)

    case result do
      {:ok, modops} -> {:ok, Enum.reverse(modops)}
      error -> error
    end
  end

  defp decode_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :invalid_schema}
      {:error, _reason} -> {:error, :invalid_schema}
    end
  end

  defp root_dir do
    Application.get_env(:fleet_capprofile, :root_dir, "cap-profiles")
  end

  # ============================================================
  # Schema validation
  # ============================================================

  defp validate_against_schema(map, kind) do
    case load_schema(kind) do
      {:ok, schema} ->
        case ExJsonSchema.Validator.validate(schema, map) do
          :ok ->
            :ok

          {:error, _errors} ->
            case kind do
              :cap_profile -> {:error, :invalid_schema}
              :modop -> {:error, :invalid_modop}
            end
        end

      {:error, :schema_unavailable} = err ->
        err
    end
  end

  defp load_schema(:cap_profile), do: load_schema_file("cap-profile-v2.5.json")
  defp load_schema(:modop), do: load_schema_file("modop-profile.json")

  defp load_schema_file(name) do
    path = Path.join(schema_dir(), name)

    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, schema} <- safe_resolve(decoded) do
      {:ok, schema}
    else
      {:error, reason} ->
        Logger.warning("schema unavailable: #{inspect(reason)} at #{path}")
        {:error, :schema_unavailable}
    end
  end

  defp safe_resolve(decoded) do
    {:ok, ExJsonSchema.Schema.resolve(decoded)}
  rescue
    e -> {:error, {:schema_resolve_error, Exception.message(e)}}
  end

  defp schema_dir do
    case Application.get_env(:fleet_capprofile, :schema_dir) do
      nil -> Path.join(to_string(:code.priv_dir(:fleet_capprofile)), "schema")
      dir -> dir
    end
  end

  defp validate_modop_keys(map) do
    case Enum.find(@reserved_modop_keys, &Map.has_key?(map, &1)) do
      nil -> :ok
      _key -> {:error, :invalid_modop}
    end
  end

  # ============================================================
  # Deep merge & canonical encoding
  # ============================================================

  defp deep_merge_last_wins(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lv, rv ->
      if is_map(lv) and is_map(rv), do: deep_merge_last_wins(lv, rv), else: rv
    end)
  end

  defp deep_merge_last_wins(_left, right), do: right

  defp canonical_json(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), canonical_json(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> Jason.encode!(k) <> ":" <> v end)
      |> Enum.join(",")

    "{" <> pairs <> "}"
  end

  defp canonical_json(list) when is_list(list) do
    inner = list |> Enum.map(&canonical_json/1) |> Enum.join(",")
    "[" <> inner <> "]"
  end

  defp canonical_json(other), do: Jason.encode!(other)

  # ============================================================
  # Struct conversion
  # ============================================================

  defp to_struct(raw) when is_map(raw) do
    %__MODULE__{
      api_version: Map.get(raw, "apiVersion"),
      kind: Map.get(raw, "kind"),
      metadata: Map.get(raw, "metadata", %{}),
      spec: Map.get(raw, "spec", %{})
    }
  end

  defp struct_to_map(%__MODULE__{} = p) do
    %{
      "apiVersion" => p.api_version,
      "kind" => p.kind,
      "metadata" => p.metadata,
      "spec" => p.spec
    }
  end

  # ============================================================
  # G24 invariants (one function per check)
  # ============================================================

  defp check_containment(%__MODULE__{metadata: meta}) do
    if Map.get(meta, "containment") in @containment_enum, do: :ok, else: :error
  end

  defp check_api_version(%__MODULE__{api_version: v}) do
    if v == @api_version_pinned, do: :ok, else: :error
  end

  defp check_kind(%__MODULE__{kind: k}) do
    if k == @kind_pinned, do: :ok, else: :error
  end

  defp check_lifetime_scope(%__MODULE__{spec: spec}) do
    # Canon : lifetime_scope nesté dans spec.invocation (schema
    # cap-profile-v2.5.json + 7 cap-profiles 05_data-canon). Le code
    # lisait spec-level (forme pré-alignement schema) → aligné canon.
    if get_in(spec, ["invocation", "lifetime_scope"]) in @lifetime_scope_enum,
      do: :ok,
      else: :error
  end

  defp check_git_ops_denied(%__MODULE__{spec: spec}) do
    denied = get_in(spec, ["scope", "git_ops_denied"]) || []
    if "push" in denied, do: :ok, else: :error
  end

  defp check_modop_incompatible(%__MODULE__{spec: spec}) do
    pairs = Map.get(spec, "modop_incompatible", [])
    active = spec |> Map.get("modop_set", []) |> MapSet.new()

    conflict? =
      Enum.any?(pairs, fn pair ->
        case pair do
          [a, b] -> MapSet.member?(active, a) and MapSet.member?(active, b)
          _ -> false
        end
      end)

    if conflict?, do: :error, else: :ok
  end

  defp check_budget(%__MODULE__{spec: spec}) do
    budget = Map.get(spec, "budget", %{})
    usd = Map.get(budget, "maxUsd", 0)
    sec = Map.get(budget, "maxDurationSec", 0)

    if is_number(usd) and is_number(sec) and usd > 0 and sec > 0,
      do: :ok,
      else: :error
  end

  defp check_metadata_name(%__MODULE__{metadata: meta}) do
    case Map.get(meta, "name") do
      name when is_binary(name) and byte_size(name) > 0 -> :ok
      _ -> :error
    end
  end

  defp check_disallowed_strict(%__MODULE__{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []
    if Enum.all?(@disallowed_minimum_strict, &(&1 in disallowed)), do: :ok, else: :error
  end

  defp check_disallowed_prefix(%__MODULE__{spec: spec}) do
    disallowed = get_in(spec, ["scope", "disallowedTools"]) || []

    prefix_ok =
      Enum.all?(@disallowed_minimum_prefix, fn prefix ->
        Enum.any?(disallowed, &String.starts_with?(&1, prefix))
      end)

    if prefix_ok, do: :ok, else: :error
  end
end
