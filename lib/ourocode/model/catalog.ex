defmodule Ourocode.Model.Catalog do
  @moduledoc """
  Detects the selectable backends, the way an installer probes a machine.

  Probes are injectable so the detection logic is pure and unit-tested:

    * `:codex_signed_in` boolean (default: `Provider.Codex.signed_in?/0`)
    * `:which`           `name -> path | nil` (default: `System.find_executable/1`)

  Codex is always listed (selecting it triggers OAuth when not yet signed
  in). CLI backends are listed only when their binary is installed.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Cli
  alias Ourocode.Provider.Codex
  alias Ourocode.Provider.Codex.Client

  @cli_labels %{
    claude: "claude cli",
    codex_cli: "codex cli",
    gemini: "gemini cli"
  }

  @doc "All backends with detected status, Codex first then installed CLIs."
  @spec list(keyword()) :: [Model.t()]
  def list(opts \\ []) do
    which = Keyword.get(opts, :which, &System.find_executable/1)
    signed_in? = Keyword.get_lazy(opts, :codex_signed_in, &Codex.signed_in?/0)

    [codex_model(signed_in?) | cli_models(which)]
  end

  @doc """
  Picks the default active model: a ready CLI if one exists, otherwise
  Codex (ready when signed in, else offered for `/login`).
  """
  @spec default(keyword()) :: Model.t()
  def default(opts \\ []) do
    models = list(opts)
    codex = Enum.find(models, &(&1.id == :codex))

    cond do
      codex && Model.ready?(codex) -> codex
      ready = Enum.find(models, &Model.ready?/1) -> ready
      true -> codex || hd(models)
    end
  end

  @doc "Looks a model up by id within an already-listed set."
  @spec fetch([Model.t()], atom()) :: Model.t() | nil
  def fetch(models, id), do: Enum.find(models, &(&1.id == id))

  @doc "Selectable rows for the picker (excludes purely unavailable backends)."
  @spec selectable([Model.t()]) :: [Model.t()]
  def selectable(models), do: Enum.reject(models, &(&1.status == :unavailable))

  defp codex_model(signed_in?) do
    %Model{
      id: :codex,
      label: "codex  (ChatGPT)",
      kind: :oauth,
      status: if(signed_in?, do: :ready, else: {:needs_auth, "/login"}),
      run: fn prompt, opts, on_chunk -> Client.stream(prompt, opts, on_chunk) end
    }
  end

  defp cli_models(which) do
    Cli.specs()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      installed? = Cli.resolve(id, which) != nil

      %Model{
        id: id,
        label: Map.get(@cli_labels, id, to_string(id)),
        kind: :cli,
        status: if(installed?, do: :ready, else: :unavailable),
        run: fn prompt, opts, on_chunk ->
          Cli.stream(id, prompt, Keyword.put(opts, :which, which), on_chunk)
        end
      }
    end)
  end
end
