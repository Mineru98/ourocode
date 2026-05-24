defmodule Ourocode.Terminal.ModelStatus do
  @moduledoc """
  Pure model status helpers for the raw TUI.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog

  @type auth_label :: {String.t(), :ok | :dim}

  @spec active_model(map(), integer(), pos_integer(), [Model.t()], (-> Model.t())) ::
          {Model.t(), map()}
  def active_model(current, now_ms, ttl_ms, models, default_model_fun)
      when is_map(current) and is_integer(now_ms) and is_integer(ttl_ms) and is_list(models) and
             is_function(default_model_fun, 0) do
    id = Map.get(current, :model_id)

    case Map.get(current, :model_cache) do
      %{id: ^id, expires_at: expires_at, model: %Model{} = model} when expires_at > now_ms ->
        {model, current}

      _stale ->
        model = Catalog.fetch(models, id) || default_model_fun.()

        {model,
         %{
           current
           | model_cache: %{id: id, expires_at: now_ms + ttl_ms, model: model}
         }}
    end
  end

  @spec auth_label(Model.t() | nil) :: auth_label()
  def auth_label(%Model{status: :ready, label: label}), do: {"model: #{label}", :ok}

  def auth_label(%Model{status: {:needs_auth, hint}, label: label}),
    do: {"model: #{label}  #{hint}", :dim}

  def auth_label(_model), do: {"no model  -  /model", :dim}
end
