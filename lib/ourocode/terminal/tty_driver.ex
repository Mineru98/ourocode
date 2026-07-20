defmodule Ourocode.Terminal.TtyDriver do
  @moduledoc """
  Native tty helper boundary for the interactive TUI.
  """

  @poll_ms 500

  @doc "Absolute path of the built tty helper, or nil if it is not present."
  @spec helper_path() :: String.t() | nil
  def helper_path do
    [
      System.get_env("OUROCODE_TTY"),
      Path.join(File.cwd!(), "rust/ourocode_ipc/target/release/ourocode_tty"),
      Path.join(File.cwd!(), "bin/ourocode_tty")
    ]
    |> helper_path()
  end

  @doc false
  @spec helper_path([String.t() | nil]) :: String.t() | nil
  def helper_path(paths) when is_list(paths) do
    Enum.find(paths, fn path -> is_binary(path) and File.exists?(path) end)
  end

  @spec start() :: {:ok, port(), {pos_integer(), pos_integer()}, binary()} | :error
  def start do
    case helper_path() do
      nil ->
        :error

      path ->
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :nouse_stdio,
            :hide
          ])

        case read_header(port, "") do
          {:ok, cols, rows, rest} ->
            write(port, enter_sequence())
            {:ok, port, {cols, rows}, rest}

          :error ->
            safe_close(port)
            :error
        end
    end
  end

  @spec stop(port() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(port) do
    write(port, exit_sequence())
    safe_close(port)
  end

  @spec write(port() | nil, iodata()) :: :ok
  def write(nil, _iodata), do: :ok

  def write(port, iodata) when is_port(port) do
    Port.command(port, IO.iodata_to_binary(iodata))
    :ok
  rescue
    _exception -> :ok
  end

  @spec next_chunk(port() | nil, non_neg_integer()) ::
          {:ok, binary()} | {:file_cache_ready, [String.t()]} | :tick | :eof
  def next_chunk(port, poll_ms \\ @poll_ms) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        {:ok, data}

      {^port, {:exit_status, _status}} ->
        :eof

      {:file_cache_ready, files} when is_list(files) ->
        {:file_cache_ready, files}
    after
      poll_ms -> :tick
    end
  end

  @spec size({pos_integer(), pos_integer()}) :: {pos_integer(), pos_integer()}
  def size(fallback) do
    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} when cols > 0 and rows > 0 -> {cols, rows}
      _other -> fallback
    end
  rescue
    _exception -> fallback
  end

  @spec tty?() :: boolean()
  def tty? do
    System.get_env("OUROCODE_FORCE_TTY") == "1" or match?({:ok, _}, :io.columns())
  end

  @doc false
  def enter_sequence, do: "\e[?1049h\e[?1006h\e[?1003h\e[?2004h\e[?25l\e[2J\e[H"

  @doc false
  def exit_sequence, do: "\e[?2004l\e[?1003l\e[?1006l\e[?25h\e[?1049l"

  @doc false
  @spec parse_header(binary()) ::
          {:ok, pos_integer(), pos_integer(), binary()} | :partial | :error
  def parse_header(data) when is_binary(data) do
    case :binary.split(data, "\n") do
      [line, rest] ->
        case line |> String.split() |> Enum.map(&Integer.parse/1) do
          [{cols, _}, {rows, _}] when cols > 0 and rows > 0 -> {:ok, cols, rows, rest}
          _invalid -> :error
        end

      [_partial] ->
        :partial
    end
  end

  defp read_header(port, acc) do
    receive do
      {^port, {:data, data}} ->
        case parse_header(acc <> data) do
          :partial -> read_header(port, acc <> data)
          parsed -> parsed
        end

      {^port, {:exit_status, _status}} ->
        :error
    after
      5_000 -> :error
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _exception -> :ok
  end
end
