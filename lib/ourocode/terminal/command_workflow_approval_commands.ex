defmodule Ourocode.Terminal.CommandWorkflowApprovalCommands do
  @moduledoc """
  Applies explicit user approval to approval-gated workflow lanes.
  """

  alias Ourocode.Terminal.RuntimeEventProcessor

  @actions [:approve_workflow]

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec dispatch(:approve_workflow, map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(:approve_workflow, command_event, state) when is_map(state) do
    case approval_target(state) do
      {:ok, pane_id, pane} ->
        approve(pane_id, pane, command_event, state)

      :error ->
        render_no_pending_approval(state)
    end
  end

  defp approval_target(%{pane_model: %{panes: panes}}) when is_map(panes) do
    panes
    |> Enum.find(fn {_pane_id, pane} -> approval_pending?(pane) end)
    |> case do
      {pane_id, pane} when is_binary(pane_id) -> {:ok, pane_id, pane}
      _none -> :error
    end
  end

  defp approval_target(_state), do: :error

  defp approval_pending?(%{kind: :workflow_session} = pane) do
    auto_workflow?(pane) and
      pending_status?(Map.get(pane, :status)) and
      approval_text?(Map.get(pane, :last_line)) and
      approval_text?(Map.get(pane, :progress))
  end

  defp approval_pending?(_pane), do: false

  defp auto_workflow?(pane) do
    [Map.get(pane, :title), Map.get(pane, :task)]
    |> Enum.any?(fn value ->
      value = value |> to_string() |> String.downcase()
      String.contains?(value, "auto workflow") or String.starts_with?(value, "ooo auto")
    end)
  end

  defp pending_status?(status) do
    status
    |> to_string()
    |> String.downcase()
    |> String.contains?(["approval", "preparing", "queued", "running"])
  end

  defp approval_text?(value) when is_list(value),
    do: Enum.any?(value, &approval_text?/1)

  defp approval_text?(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.contains?("approval")
  end

  defp approve(pane_id, pane, command_event, state) do
    with {:ok, sandbox} <- execute_sandbox_approval(pane_id) do
      events = approval_events(pane_id, pane, command_event, sandbox)

      case submit_events(state, events) do
        {:ok, state} ->
          IO.puts(state.output, approval_text(pane_id, sandbox))

          {:ok,
           %{
             state: state,
             approval: %{
               status: :approved_sandbox_execution,
               pane_id: pane_id,
               sandbox_path: sandbox.path
             }
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_sandbox_approval(pane_id) do
    root =
      Path.join([
        System.tmp_dir!(),
        "ourocode-auto-approval-#{System.unique_integer([:positive])}"
      ])

    path = Path.join(root, "approved-execution.txt")
    content = "approved #{pane_id} at #{System.system_time(:millisecond)}\n"

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(path, content),
         {:ok, ^content} <- File.read(path) do
      {:ok, %{root: root, path: path, bytes: byte_size(content)}}
    else
      {:ok, other} -> {:error, {:sandbox_verification_mismatch, other}}
      {:error, reason} -> {:error, {:sandbox_execution_failed, reason}}
    end
  end

  defp approval_events(pane_id, pane, command_event, sandbox) do
    parent_call_id = Map.get(pane, :parent_call_id, "manual-approval")
    source_command = Map.get(command_event, :command, "/approve")

    [
      %{
        type: :stream_event,
        pane_id: pane_id,
        phase: "execute sandbox",
        current: "approval accepted; sandbox execution applied",
        progress: [
          "approval recorded",
          "sandbox file changed",
          "#{sandbox.bytes} bytes verified",
          "project files unchanged"
        ],
        controls: ["inspect sandbox", "run verify", "cancel"],
        line:
          "manual approval recorded by #{source_command}; sandbox file changed at #{sandbox.path}",
        parent_call_id: parent_call_id,
        focused?: true
      },
      %{
        type: :stream_event,
        pane_id: pane_id,
        phase: "verify sandbox",
        current:
          "sandbox verification passed; project mutation still requires explicit execution",
        progress: [
          "approval journaled",
          "sandbox verified",
          sandbox.path,
          "project files unchanged"
        ],
        controls: ["run /verify", "inspect evidence", "start execution"],
        line: "sandbox verification evidence ready",
        parent_call_id: parent_call_id,
        focused?: true
      }
    ]
  end

  defp submit_events(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case RuntimeEventProcessor.submit(event, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp approval_text(pane_id, sandbox) do
    [
      "approval: sandbox execution accepted",
      "  work item: #{pane_id}",
      "  result: changed and verified a temporary sandbox file",
      "  file: #{sandbox.path}",
      "  project: unchanged",
      "  next: inspect the plan, then run project implementation explicitly"
    ]
    |> Enum.join("\n")
  end

  defp render_no_pending_approval(%{output: output}) when is_pid(output) do
    IO.puts(output, no_pending_text())
    {:ok, %{approval: %{status: :no_pending_approval}}}
  end

  defp render_no_pending_approval(_state), do: {:ok, %{approval: %{status: :no_pending_approval}}}

  defp no_pending_text do
    [
      "approval: no pending auto workflow",
      "  start with ooo auto <goal> and wait for the approval checkpoint"
    ]
    |> Enum.join("\n")
  end
end
