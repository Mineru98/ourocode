defmodule Ourocode.Terminal.ConversationStore do
  @moduledoc """
  Best-effort persistence for the direct-chat conversation.

  One JSON file per project under the shared state dir, so a restarted TUI
  resumes the dialogue where the previous run stopped. Persistence is UX
  state in the `PromptStore` sense: store failures never block chat, and the
  journal remains the authoritative event history.
  """

  alias Ourocode.Json
  alias Ourocode.Model.Conversation

  @doc "Project dir as carried by the startup result, or nil when absent."
  @spec project_dir(map()) :: String.t() | nil
  def project_dir(%{context: %{project_dir: project_dir}}) when is_binary(project_dir),
    do: project_dir

  def project_dir(%{project_dir: project_dir}) when is_binary(project_dir), do: project_dir
  def project_dir(_result), do: nil

  @spec load(String.t() | nil, keyword()) :: Conversation.t()
  def load(project_dir, opts \\ []) do
    with path when is_binary(path) <- path(project_dir, opts),
         {:ok, body} <- File.read(path),
         {:ok, %{"turns" => turns}} <- Json.decode(body) do
      Conversation.from_list(turns)
    else
      _missing_or_invalid -> Conversation.new()
    end
  rescue
    _exception -> Conversation.new()
  end

  @spec save(String.t() | nil, Conversation.t(), keyword()) :: :ok
  def save(project_dir, %Conversation{} = conversation, opts \\ []) do
    case path(project_dir, opts) do
      nil ->
        :ok

      path ->
        _ = File.mkdir_p(Path.dirname(path))
        _ = File.write(path, Json.encode!(%{"turns" => Conversation.to_list(conversation)}))
        :ok
    end
  rescue
    _exception -> :ok
  end

  @spec clear(String.t() | nil, keyword()) :: :ok
  def clear(project_dir, opts \\ []) do
    case path(project_dir, opts) do
      nil -> :ok
      path -> File.rm(path) && :ok
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp path(nil, _opts), do: nil

  defp path(project_dir, opts) when is_binary(project_dir) do
    Path.join([state_dir(opts), "chat", file_name(project_dir)])
  end

  # Readable slug plus a short content hash: two projects whose basenames
  # sanitize to the same slug still get distinct files.
  defp file_name(project_dir) do
    expanded = Path.expand(project_dir)
    slug = expanded |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "-")

    hash =
      :sha256
      |> :crypto.hash(expanded)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    slug <> "-" <> hash <> ".json"
  end

  defp state_dir(opts) do
    Keyword.get(opts, :state_dir) ||
      System.get_env("OUROCODE_STATE_DIR") ||
      Path.join(System.user_home!(), ".ourocode")
  end
end
