defmodule Ourocode.Plugin.MappingSignatureVerifier do
  @moduledoc """
  Verifies signed declarative plugin mappings.

  Official mapping signatures are data signatures over the mapping type,
  canonical official plugin identity, and mapping body with the `signature`
  field removed. The MVP verifier supports HMAC-SHA256 keys supplied by config
  or loader options so tests and local installations can exercise the trust
  boundary without adding runtime dependencies.
  """

  alias Ourocode.Json

  @app :ourocode
  @official_plugin_id "ouroboros-plugin"
  @supported_algorithm "hmac-sha256"

  @type mapping_type :: :adapter | :renderer | :action
  @type verification_error ::
          :invalid_mapping_signature
          | :invalid_mapping_signature_config
          | :missing_mapping_signature
          | :unsupported_mapping_signature_algorithm
          | :unknown_mapping_signature_key

  @doc """
  Verifies every signed mapping in a mapping list.

  Official declarative adapter, renderer, and action mappings must include a
  signature. Missing or invalid signatures are rejected before the mapping can
  be installed into a registry.

  Options:

    * `:official_mapping_signing_keys` - `%{"key-id" => "secret"}` or
      `[%{key_id: "key-id", secret: "secret"}]`. Defaults to
      `Application.get_env(:ourocode, :official_mapping_signing_keys, %{})`.
  """
  @spec verify_all(mapping_type(), map(), list(map()), keyword()) ::
          :ok | {:error, verification_error()}
  def verify_all(mapping_type, plugin, mappings, opts \\ [])
      when mapping_type in [:adapter, :renderer, :action] and is_map(plugin) and
             is_list(mappings) do
    Enum.reduce_while(mappings, :ok, fn mapping, :ok ->
      case verify(mapping_type, plugin, mapping, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Verifies one required mapping signature.
  """
  @spec verify(mapping_type(), map(), map(), keyword()) :: :ok | {:error, verification_error()}
  def verify(mapping_type, plugin, mapping, opts \\ [])
      when mapping_type in [:adapter, :renderer, :action] and is_map(plugin) and is_map(mapping) do
    case Map.get(mapping, "signature") do
      nil -> {:error, :missing_mapping_signature}
      signature when is_map(signature) ->
        verify_signature(mapping_type, plugin, mapping, signature, opts)

      _other -> {:error, :invalid_mapping_signature}
    end
  end

  @doc """
  Returns the canonical payload bytes covered by a mapping signature.
  """
  @spec payload(mapping_type(), map(), map()) :: binary()
  def payload(mapping_type, plugin, mapping)
      when mapping_type in [:adapter, :renderer, :action] and is_map(plugin) and is_map(mapping) do
    %{
      "mapping" => Map.delete(mapping, "signature"),
      "mapping_type" => Atom.to_string(mapping_type),
      "plugin_id" => Map.get(plugin, :plugin_id, @official_plugin_id),
      "trust_classification" => Map.get(plugin, :trust_classification, "official_trusted")
    }
    |> canonical_json()
  end

  @doc """
  Signs a mapping payload with an HMAC-SHA256 key.

  This helper is intentionally generic and is used by positive-path tests to
  construct fixture manifests with real verifiable signatures.
  """
  @spec sign(mapping_type(), map(), map(), binary()) :: binary()
  def sign(mapping_type, plugin, mapping, secret)
      when is_binary(secret) do
    :hmac
    |> hmac_sha256(secret, payload(mapping_type, plugin, mapping))
    |> Base.encode64(padding: false)
  end

  defp verify_signature(mapping_type, plugin, mapping, signature, opts) do
    with {:ok, key_id} <- signature_field(signature, "key_id"),
         {:ok, algorithm} <- signature_field(signature, "algorithm"),
         {:ok, value} <- signature_field(signature, "value"),
         :ok <- validate_algorithm(algorithm),
         {:ok, secret} <- signing_secret(key_id, opts) do
      expected = sign(mapping_type, plugin, mapping, secret)

      if secure_equal?(expected, value) do
        :ok
      else
        {:error, :invalid_mapping_signature}
      end
    end
  end

  defp signature_field(signature, field) do
    case Map.get(signature, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_mapping_signature}
    end
  end

  defp validate_algorithm(@supported_algorithm), do: :ok
  defp validate_algorithm(_algorithm), do: {:error, :unsupported_mapping_signature_algorithm}

  defp signing_secret(key_id, opts) do
    case normalized_keys(opts) do
      {:ok, keys} ->
        case Map.fetch(keys, key_id) do
          {:ok, secret} -> {:ok, secret}
          :error -> {:error, :unknown_mapping_signature_key}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalized_keys(opts) do
    opts
    |> Keyword.get(
      :official_mapping_signing_keys,
      Application.get_env(@app, :official_mapping_signing_keys, %{})
    )
    |> normalize_keys()
  end

  defp normalize_keys(keys) when is_map(keys) do
    if Enum.all?(keys, fn {key_id, secret} -> is_binary(key_id) and is_binary(secret) end) do
      {:ok, keys}
    else
      {:error, :invalid_mapping_signature_config}
    end
  end

  defp normalize_keys(keys) when is_list(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      with {:ok, key_id} <- key_value(key, :key_id),
           {:ok, secret} <- key_value(key, :secret) do
        {:cont, {:ok, Map.put(acc, key_id, secret)}}
      else
        :error -> {:halt, {:error, :invalid_mapping_signature_config}}
      end
    end)
  end

  defp normalize_keys(_keys), do: {:error, :invalid_mapping_signature_config}

  defp key_value(key, field) when is_map(key) do
    value = Map.get(key, field) || Map.get(key, Atom.to_string(field))

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      :error
    end
  end

  defp key_value(_key, _field), do: :error

  defp canonical_json(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, member_value} ->
        [Json.encode!(to_string(key)), ":", canonical_json(member_value)]
      end)
      |> Enum.intersperse(",")

    IO.iodata_to_binary(["{", members, "}"])
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map(&canonical_json/1)
    |> Enum.intersperse(",")
    |> then(&IO.iodata_to_binary(["[", &1, "]"]))
  end

  defp canonical_json(value), do: IO.iodata_to_binary(Json.encode!(value))

  defp hmac_sha256(:hmac, secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      left
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(right))
      |> Enum.reduce(0, fn {left_byte, right_byte}, diff ->
        Bitwise.bor(diff, Bitwise.bxor(left_byte, right_byte))
      end)
      |> Kernel.==(0)
    else
      false
    end
  end
end
