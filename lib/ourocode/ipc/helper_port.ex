defmodule Ourocode.IPC.HelperPort do
  @moduledoc false

  @spec open_and_write(Path.t(), [String.t()], iodata()) :: {:ok, port()} | {:error, term()}
  def open_and_write(command, args, frame) do
    with {:ok, port} <- open(command, args) do
      case write_frame(port, frame) do
        :ok ->
          {:ok, port}

        {:error, reason} ->
          close(port)
          {:error, reason}
      end
    end
  end

  @spec close(port()) :: :ok
  def close(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp open(command, args) do
    {:ok,
     Port.open({:spawn_executable, command}, [
       :binary,
       :exit_status,
       {:args, args},
       {:line, 65_536}
     ])}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp write_frame(port, frame) do
    if Port.command(port, frame) do
      :ok
    else
      {:error, :closed}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
