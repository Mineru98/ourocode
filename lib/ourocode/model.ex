defmodule Ourocode.Model do
  @moduledoc """
  A selectable main-session backend ("model").

  The runtime stays provider-agnostic: it talks to whatever `Model` is
  active, never to a specific vendor. A model is a small value:

    * `id`     stable atom used for selection/persistence
    * `label`  human row in the `/model` picker
    * `kind`   `:oauth` (Codex), `:cli` (a local agent CLI), `:mcp` (later)
    * `status` `:ready` | `{:needs_auth, hint}` | `:unavailable`
    * `run`    `fn prompt, opts, on_chunk -> {:ok, text} | {:error, term} end`

  Codex keeps its in-TUI OAuth (`status` becomes `{:needs_auth, "/login"}`
  until signed in). Every other backend is something the developer is
  already authenticated for in their terminal, so it is detected and reused
  with zero login. Grouping providers behind MCP later is just another
  `kind`; nothing else in the runtime changes.
  """

  @enforce_keys [:id, :label, :kind, :status, :run]
  defstruct [:id, :label, :kind, :status, :run]

  @type status :: :ready | {:needs_auth, String.t()} | :unavailable
  @type runner :: (String.t(), keyword(), (String.t() -> any()) ->
                     {:ok, String.t()} | {:error, term()})

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          kind: :oauth | :cli | :mcp,
          status: status(),
          run: runner()
        }

  @doc "True when the model can serve a turn right now (no auth step needed)."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{status: :ready}), do: true
  def ready?(%__MODULE__{}), do: false

  @doc "True when the model exists but needs an auth step before use."
  @spec needs_auth?(t()) :: boolean()
  def needs_auth?(%__MODULE__{status: {:needs_auth, _}}), do: true
  def needs_auth?(%__MODULE__{}), do: false

  @doc "Streams a turn through this model."
  @spec stream(t(), String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(%__MODULE__{run: run}, prompt, opts, on_chunk)
      when is_function(run, 3) and is_binary(prompt) do
    run.(prompt, opts, on_chunk)
  end
end
