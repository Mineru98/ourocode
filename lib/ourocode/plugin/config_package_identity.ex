defmodule Ourocode.Plugin.ConfigPackageIdentity do
  @moduledoc """
  Parses and serializes package identity fields from plugin configuration.
  """

  alias Ourocode.Plugin.ConfigSchema.PackageIdentity

  @package_identity_pattern ~r/^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?(?:\/[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?)*$/
  @semantic_version_pattern ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/

  @type schema_result(value) ::
          {:ok, value} | {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), map(), non_neg_integer()) :: schema_result(PackageIdentity.t())
  def parse(plugin, identity, index) when is_map(plugin) and is_map(identity) do
    with {:ok, package} <- optional_map_field(plugin, "package", index),
         {:ok, name} <-
           first_optional_package_string(
             [
               {identity, "name", "identity.name"},
               {package, "name", "package.name"},
               {package, "package", "package.package"}
             ],
             index
           ),
         {:ok, version} <- package_version(plugin, identity, package, index),
         {:ok, publisher} <-
           first_optional_package_string(
             [
               {identity, "publisher", "identity.publisher"},
               {package, "publisher", "package.publisher"}
             ],
             index
           ),
         {:ok, namespace} <-
           first_optional_package_string(
             [
               {identity, "namespace", "identity.namespace"},
               {package, "namespace", "package.namespace"}
             ],
             index
           ) do
      {:ok,
       %PackageIdentity{
         id: Map.fetch!(identity, "id"),
         name: name,
         version: version,
         publisher: publisher,
         namespace: namespace,
         package: package
       }}
    end
  end

  @spec to_map(PackageIdentity.t() | nil) :: map() | nil
  def to_map(%PackageIdentity{} = package_identity) do
    %{
      "id" => package_identity.id,
      "name" => package_identity.name,
      "version" => package_identity.version,
      "publisher" => package_identity.publisher,
      "namespace" => package_identity.namespace,
      "package" => package_identity.package
    }
  end

  def to_map(nil), do: nil

  @spec to_package_config(map()) :: map()
  def to_package_config(package_identity) when is_map(package_identity) do
    package_identity
    |> Map.take(["name", "version", "publisher", "namespace", "package"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec validate_identity(String.t(), String.t(), non_neg_integer()) :: schema_result(String.t())
  def validate_identity("@" <> scoped_name = value, label, index) do
    case String.split(scoped_name, "/", parts: 2) do
      [scope, package] when scope != "" and package != "" ->
        if valid_package_segment?(scope) and valid_package_segment?(package) do
          {:ok, value}
        else
          invalid_package_identity(label, index)
        end

      _invalid ->
        invalid_package_identity(label, index)
    end
  end

  def validate_identity(value, label, index) when is_binary(value) do
    if Regex.match?(@package_identity_pattern, value) do
      {:ok, value}
    else
      invalid_package_identity(label, index)
    end
  end

  defp first_optional_package_string(candidates, index) do
    Enum.reduce_while(candidates, {:ok, nil}, fn {map, key, label}, {:ok, nil} ->
      case optional_package_string(map, key, label, index) do
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:ok, value} -> {:halt, {:ok, value}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp optional_package_string(nil, _key, _label, _index), do: {:ok, nil}

  defp optional_package_string(map, key, label, index) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        validate_package_field(value, label, index)

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{label} must be a non-empty string")
    end
  end

  defp package_version(plugin, identity, package, index) do
    with {:ok, config_version} <- optional_package_string(plugin, "version", "version", index),
         {:ok, identity_version} <-
           optional_package_string(identity, "version", "identity.version", index),
         {:ok, package_version} <-
           optional_package_string(package, "version", "package.version", index) do
      case config_version || identity_version || package_version do
        nil ->
          schema_error(
            "plugins[#{index}].version is required; set version, identity.version, or package.version to a non-empty string"
          )

        version ->
          validate_semantic_version(version, index)
      end
    end
  end

  defp optional_map_field(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be an object")
    end
  end

  defp validate_package_field(value, "package.name" = label, index) do
    validate_identity(value, label, index)
  end

  defp validate_package_field(value, "package.package" = label, index) do
    validate_identity(value, label, index)
  end

  defp validate_package_field(value, "identity.namespace" = label, index) do
    validate_identity(value, label, index)
  end

  defp validate_package_field(value, "package.namespace" = label, index) do
    validate_identity(value, label, index)
  end

  defp validate_package_field(value, _label, _index), do: {:ok, value}

  defp valid_package_segment?(segment), do: Regex.match?(@package_identity_pattern, segment)

  defp invalid_package_identity(label, index) do
    schema_error("plugins[#{index}].#{label} must use package identity format")
  end

  defp validate_semantic_version(version, index) do
    if Regex.match?(@semantic_version_pattern, version) do
      {:ok, version}
    else
      schema_error("plugins[#{index}].version must be a semantic version")
    end
  end

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
