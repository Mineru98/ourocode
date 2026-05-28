defmodule Ourocode.Terminal.CommandModelCommands do
  @moduledoc """
  Product-facing model picker/status renderer for `/model`.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Terminal.WorkspaceText

  @actions [:select_model]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(:select_model, map()) :: {:ok, map()}
  def render(:select_model, state) do
    models = Catalog.list()
    default = Catalog.default()
    workspace = workspace(models, default)

    IO.puts(state.output, WorkspaceText.render(workspace))
    {:ok, %{status: :rendered, workspace: workspace, count: length(models)}}
  end

  defp workspace(models, default) do
    records =
      models
      |> Enum.map(&model_record(&1, default))

    %{
      kind: "model",
      title: "Models",
      status: model_status(records),
      selected: default_record_id(default),
      records: records,
      detail: selected_detail(records, default_record_id(default)),
      actions: [
        action("login", "Sign in", "/login", "l"),
        action("detect", "Detect models", "ourocode --detect", "d"),
        action("verify", "Run health checks", "/verify", "v")
      ],
      shortcuts: ["Up/Dn rows", "Enter select", "type to compose"],
      next: "Use /login for ChatGPT, or choose a ready CLI backend."
    }
  end

  defp model_record(%Model{} = model, default) do
    active? = model.id == default.id

    %{
      id: model_id(model),
      title: model.label,
      state: if(active?, do: "active", else: model_state(model.status)),
      health: model_health(model.status),
      fields: %{
        provider: model_kind(model.kind),
        status: status_text(model.status),
        controls: model_controls(model.status)
      },
      actions: model_actions(model)
    }
  end

  defp selected_detail(records, selected_id) do
    Enum.find(records, &(Map.get(&1, :id) == selected_id)) || List.first(records) ||
      %{title: "No model detected.", state: "empty", fields: %{}}
  end

  defp model_status(records) do
    ready = Enum.count(records, &(Map.get(&1, :health) == "ready"))
    "#{ready} ready"
  end

  defp model_id(%Model{id: id}), do: "model:" <> Atom.to_string(id)
  defp default_record_id(%Model{} = model), do: model_id(model)
  defp model_kind(:oauth), do: "ChatGPT sign-in"
  defp model_kind(:cli), do: "local CLI"
  defp model_kind(kind), do: Atom.to_string(kind)

  defp model_state(:ready), do: "ready"
  defp model_state({:needs_auth, _hint}), do: "needs sign-in"
  defp model_state(:unavailable), do: "not installed"

  defp model_health(:ready), do: "ready"
  defp model_health({:needs_auth, _hint}), do: "action needed"
  defp model_health(:unavailable), do: "missing"

  defp status_text(:ready), do: "ready to use"
  defp status_text({:needs_auth, hint}), do: "sign in with #{hint}"
  defp status_text(:unavailable), do: "not installed"

  defp model_controls(:ready), do: ["select", "verify", "switch anytime"]
  defp model_controls({:needs_auth, hint}), do: [hint, "then select"]
  defp model_controls(:unavailable), do: ["install CLI", "run detect"]

  defp model_actions(%Model{status: {:needs_auth, _hint}}) do
    [action("login", "Sign in", "/login", "Enter")]
  end

  defp model_actions(%Model{status: :ready}) do
    [action("select", "Select model", "/model", "Enter"), action("verify", "Verify", "/verify", "v")]
  end

  defp model_actions(_model), do: [action("detect", "Detect models", "ourocode --detect", "d")]

  defp action(id, label, command, shortcut) do
    %{id: id, label: label, command: command, shortcut: shortcut, enabled: true}
  end
end
