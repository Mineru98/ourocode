defmodule Ourocode.IPC.HelperConfig do
  @moduledoc false

  @app :ourocode

  @spec resolve(map()) :: {:ok, map()} | {:error, term()}
  def resolve(%{helper: helper}) when not is_nil(helper) do
    helper
    |> configured_helper()
    |> normalize(helper)
  end

  def resolve(%{command: command, args: args}) do
    normalize(%{command: command, args: args}, :inline)
  end

  @spec normalize(term(), term()) :: {:ok, map()} | {:error, term()}
  def normalize(nil, helper) do
    {:error, {:missing_helper_config, helper}}
  end

  def normalize(config, helper) when is_map(config) do
    command =
      Map.get(config, :command) || Map.get(config, "command") || Map.get(config, :path) ||
        Map.get(config, "path")

    args = Map.get(config, :args) || Map.get(config, "args") || []
    version = Map.get(config, :version) || Map.get(config, "version")

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, {:invalid_helper_command, helper}}

      not is_list(args) or not Enum.all?(args, &is_binary/1) ->
        {:error, {:invalid_helper_args, helper}}

      not is_nil(version) and not is_binary(version) ->
        {:error, {:invalid_helper_version, helper}}

      true ->
        {:ok, %{name: helper, command: command, args: args, version: version}}
    end
  end

  def normalize(command, helper) when is_binary(command) do
    normalize(%{command: command}, helper)
  end

  def normalize(_config, helper) do
    {:error, {:invalid_helper_config, helper}}
  end

  defp configured_helper(helper) do
    helpers = Application.get_env(@app, :rust_helpers, %{})
    helper_key = helper_key(helper)

    cond do
      is_map(helpers) and Map.has_key?(helpers, helper) ->
        Map.fetch!(helpers, helper)

      is_map(helpers) and is_binary(helper_key) and Map.has_key?(helpers, helper_key) ->
        Map.fetch!(helpers, helper_key)

      true ->
        nil
    end
  end

  defp helper_key(helper) when is_atom(helper), do: Atom.to_string(helper)
  defp helper_key(helper) when is_binary(helper), do: helper
  defp helper_key(_helper), do: nil
end
