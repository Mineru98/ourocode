defmodule Ourocode.Terminal.RendererOverlaySlot do
  @moduledoc false

  alias Ourocode.Terminal.{Palette, RendererOverlay, Suggestions}

  @type t ::
          :none
          | {:palette, map()}
          | {:model, map()}
          | {:resource_mentions, list(), non_neg_integer()}
          | {:file_mentions, list(), non_neg_integer()}
          | {:ooo_suggestions, list(), non_neg_integer()}
          | {:key_help, atom(), map()}

  @spec build(String.t(), atom(), map()) :: t()
  def build(prompt_buffer, mode, opts) when is_binary(prompt_buffer) and is_map(opts) do
    wonder_focus = Map.get(opts, :wonder_focus, false)
    pidx = Map.get(opts, :pidx, 0)
    file_mentions = Map.get(opts, :file_mentions, [])

    resource_mentions =
      Suggestions.resource_mention_suggestions(prompt_buffer, mode, wonder_focus, opts)

    ooo_suggestions =
      Suggestions.ooo_suggestions(prompt_buffer, mode, wonder_focus, Map.get(opts, :ooo_commands))

    cond do
      palette = Map.get(opts, :palette) ->
        {:palette, palette}

      model = Map.get(opts, :model) ->
        {:model, model}

      resource_mentions != [] ->
        {:resource_mentions, resource_mentions, Palette.clamp(pidx, length(resource_mentions))}

      file_mentions != [] ->
        {:file_mentions, file_mentions, Palette.clamp(pidx, length(file_mentions))}

      ooo_suggestions != [] ->
        {:ooo_suggestions, ooo_suggestions, Palette.clamp(pidx, length(ooo_suggestions))}

      Map.get(opts, :key_help, false) ->
        {:key_help, mode, opts}

      true ->
        :none
    end
  end

  @spec draw(any(), pos_integer(), integer(), t()) :: any()
  def draw(screen, width, anchor_bottom, {:palette, palette}) do
    RendererOverlay.draw_palette(screen, width, anchor_bottom, palette)
  end

  def draw(screen, width, anchor_bottom, {:model, model}) do
    RendererOverlay.draw_model(screen, width, anchor_bottom, model)
  end

  def draw(screen, width, anchor_bottom, {:resource_mentions, suggestions, index}) do
    RendererOverlay.draw_resource_mentions(screen, width, anchor_bottom, suggestions, index)
  end

  def draw(screen, width, anchor_bottom, {:file_mentions, suggestions, index}) do
    RendererOverlay.draw_file_mentions(screen, width, anchor_bottom, suggestions, index)
  end

  def draw(screen, width, anchor_bottom, {:ooo_suggestions, suggestions, index}) do
    RendererOverlay.draw_ooo_suggestions(screen, width, anchor_bottom, suggestions, index)
  end

  def draw(screen, width, anchor_bottom, {:key_help, mode, opts}) do
    RendererOverlay.draw_key_help(screen, width, anchor_bottom, mode, opts)
  end

  def draw(screen, _width, _anchor_bottom, :none), do: screen
end
