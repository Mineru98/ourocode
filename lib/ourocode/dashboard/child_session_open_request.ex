defmodule Ourocode.Dashboard.ChildSessionOpenRequest do
  @moduledoc """
  Builds pure create-open requests for child/session panes.

  The caller remains responsible for deciding whether an existing pane should
  be reused and for applying the resulting request to dashboard state.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata

  @type request :: %{
          required(:action) => :create_open,
          required(:kind) => :child_session_create_open_request,
          required(:child_id) => String.t(),
          required(:pane_id) => String.t(),
          required(:selected_identifier) => String.t(),
          required(:parent_call_id) => term(),
          required(:runtime_source) => term(),
          required(:transport) => term(),
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map()
        }

  @spec normalize_identifier(term()) ::
          {:ok, String.t()} | {:error, :invalid_child_session_identifier}
  def normalize_identifier(identifier) do
    case ChildSessionMetadata.normalize_runtime_id(identifier) do
      nil -> {:error, :invalid_child_session_identifier}
      identifier -> {:ok, identifier}
    end
  end

  @spec child_id(String.t()) :: {:ok, String.t()} | {:error, :invalid_child_session_identifier}
  def child_id("child-session:" <> child_id) do
    normalize_identifier(child_id)
  end

  def child_id(child_id), do: {:ok, child_id}

  @spec pane_id(map(), String.t()) :: String.t()
  def pane_id(registry, child_id) when is_map(registry) and is_binary(child_id) do
    Map.get(registry, child_id, ChildSessionIdentity.pane_id(child_id))
  end

  @spec build(String.t(), String.t(), String.t(), map() | keyword()) :: request()
  def build(child_id, identifier, pane_id, options)
      when is_binary(child_id) and is_binary(identifier) and is_binary(pane_id) do
    options = Map.new(options)
    external_ids = ChildSessionMetadata.map_value(options, :external_ids, %{})

    %{
      action: :create_open,
      kind: :child_session_create_open_request,
      child_id: child_id,
      pane_id: pane_id,
      selected_identifier: identifier,
      parent_call_id: ChildSessionMetadata.value(options, :parent_call_id),
      runtime_source: ChildSessionMetadata.value(options, :runtime_source),
      transport: ChildSessionMetadata.value(options, :transport),
      external_ids: Map.put_new(external_ids, "childID", child_id),
      stream_cursor: ChildSessionMetadata.map_value(options, :stream_cursor, %{}),
      pane_state:
        %{
          open?: true,
          focused?: true,
          renderer: :default_child_session
        }
        |> Map.merge(ChildSessionMetadata.map_value(options, :pane_state, %{}))
    }
  end

  @spec metadata(request(), boolean()) :: map()
  def metadata(request, focused?) when is_map(request) and is_boolean(focused?) do
    %{
      child_id: ChildSessionMetadata.value(request, :child_id),
      parent_call_id: ChildSessionMetadata.value(request, :parent_call_id),
      runtime_source: ChildSessionMetadata.value(request, :runtime_source),
      transport: ChildSessionMetadata.value(request, :transport),
      external_ids: ChildSessionMetadata.map_value(request, :external_ids, %{}),
      stream_cursor: ChildSessionMetadata.map_value(request, :stream_cursor, %{}),
      pane_state:
        request
        |> ChildSessionMetadata.map_value(:pane_state, %{})
        |> Map.put(:focused?, focused?)
    }
  end
end
