defmodule Red.Connection do
  @moduledoc false

  use Connection

  alias Red.Protocol
  require Logger

  @initial_state %{
    socket: nil,
    tail: "",
    opts: nil,
    queue: :queue.new,
  }

  @socket_opts [:binary, active: false]

  ## Callbacks

  @doc false
  def init(opts) do
    {:connect, :init, Dict.merge(@initial_state, opts: opts)}
  end

  @doc false
  def connect(info, s)

  def connect(_info, %{opts: opts} = s) do
    {host, port, socket_opts} = tcp_connection_opts(opts)

    case :gen_tcp.connect(host, port, socket_opts) do
      {:ok, socket} ->
        setup_socket_buffers(socket)
        auth_and_select_db(%{s | socket: socket})
      {:error, reason} ->
        {:stop, reason, s}
    end
  end

  @doc false
  def disconnect(reason, s)

  def disconnect(:stop, %{socket: nil} = s) do
    {:stop, :normal, s}
  end

  def disconnect(:stop, %{socket: socket} = s) do
    :gen_tcp.close(socket)
    {:stop, :normal, %{s | socket: nil}}
  end

  def disconnect({:error, reason} = error, %{socket: socket, queue: queue} = s) do
    Logger.error "[Red] Disconnected from Redis (#{inspect reason})"

    queue
    |> :queue.to_list
    |> Stream.map(&extract_client_from_queued_item/1)
    |> Enum.map(&Connection.reply(&1, error))

    # Backoff with 0 to churn through all the commands in the mailbox before
    # reconnecting.
    s = %{s | socket: nil, queue: :queue.new, tail: ""}
    {:backoff, 0, s}
  end

  @doc false
  def handle_call(operation, from, s)

  def handle_call(_operation, _from, %{socket: nil} = s) do
    {:reply, {:error, :closed}, s}
  end

  def handle_call({:command, args}, from, s) do
    s
    |> enqueue({:command, from})
    |> send_noreply(Protocol.pack(args))
  end

  def handle_call({:pipeline, commands}, from, s) do
    s
    |> enqueue({:pipeline, from, length(commands)})
    |> send_noreply(Enum.map(commands, &Protocol.pack/1))
  end

  @doc false
  def handle_cast(operation, s)

  def handle_cast(:stop, s) do
    {:disconnect, :stop, s}
  end

  @doc false
  def handle_info(msg, s)

  def handle_info({:tcp, socket, data}, %{socket: socket} = s) do
    reactivate_socket(s)
    s = new_data(s, s.tail <> data)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s) do
    {:disconnect, {:error, :tcp_closed}, s}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = s) do
    {:disconnect, {:error, reason}, s}
  end

  ## Helper functions

  defp new_data(s, <<>>) do
    %{s | tail: <<>>}
  end

  defp new_data(s, data) do
    {from, parser, new_queue} = dequeue(s)

    case parser.(data) do
      {:ok, resp, rest} ->
        Connection.reply(from, format_resp(resp))
        s = %{s | queue: new_queue}
        new_data(s, rest)
      {:error, :incomplete} ->
        %{s | tail: data}
    end
  end

  defp dequeue(s) do
    case :queue.out(s.queue) do
      {{:value, {:command, from}}, new_queue} ->
        {from, &Protocol.parse/1, new_queue}
      {{:value, {:pipeline, from, ncommands}}, new_queue} ->
        {from, &Protocol.parse_multi(&1, ncommands), new_queue}
      {:empty, _} ->
        raise "still got data but the queue is empty"
    end
  end

  defp send_noreply(%{socket: socket} = s, data) do
    case :gen_tcp.send(socket, data) do
      :ok ->
        {:noreply, s}
      {:error, _reason} = error ->
        {:disconnect, error, s}
    end
  end

  # Enqueues `val` in the state.
  defp enqueue(%{queue: queue} = s, val) do
    %{s | queue: :queue.in(val, queue)}
  end

  # Extracts the TCP connection options (host, port and socket opts) from the
  # given `opts`.
  defp tcp_connection_opts(opts) do
    host = to_char_list(Keyword.fetch!(opts, :host))
    port = Keyword.fetch!(opts, :port)
    socket_opts = @socket_opts ++ Keyword.fetch!(opts, :socket_opts)

    {host, port, socket_opts}
  end

  # Reactivates the socket with `active: :once`.
  defp reactivate_socket(%{socket: socket} = _s) do
    :ok = :inet.setopts(socket, active: :once)
  end

  # Setups the `:buffer` option of the given socket.
  defp setup_socket_buffers(socket) do
    {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
      :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])

    buffer = buffer |> max(sndbuf) |> max(recbuf)
    :ok = :inet.setopts(socket, [buffer: buffer])
  end

  defp extract_client_from_queued_item({:command, from}), do: from
  defp extract_client_from_queued_item({:pipeline, from, _}), do: from

  defp format_resp(%Red.Error{} = err), do: {:error, err}
  defp format_resp(resp), do: {:ok, resp}

  defp auth_and_select_db(s) do
    case auth(s, s.opts[:password]) do
      {:ok, s} ->
        case select_db(s, s.opts[:database]) do
          {:ok, s} ->
            reactivate_socket(s)
            {:ok, s}
          o ->
            o
        end
      o ->
        o
    end
  end

  defp auth(s, nil) do
    {:ok, s}
  end

  defp auth(%{socket: socket} = s, password) when is_binary(password) do
    case :gen_tcp.send(socket, Protocol.pack(["AUTH", password])) do
      :ok ->
        case wait_for_response(s) do
          {:ok, "OK", s} ->
            {:ok, s}
          {:ok, error, s} ->
            {:stop, error, s}
          {:error, reason} ->
            {:stop, reason, s}
        end
      {:error, reason} ->
        {:stop, reason, s}
    end
  end

  defp auth(s, nil) do
    {:ok, s}
  end

  defp select_db(%{socket: socket} = s, db) do
    case :gen_tcp.send(socket, Protocol.pack(["SELECT", db])) do
      :ok ->
        case wait_for_response(s) do
          {:ok, "OK", s} ->
            {:ok, s}
          {:ok, error, s} ->
            {:stop, error, s}
          {:error, reason} ->
            {:stop, reason, s}
        end
      {:error, reason} ->
        {:stop, reason, s}
    end
  end

  defp wait_for_response(%{socket: socket} = s) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        data = s.tail <> data
        case Protocol.parse(data) do
          {:ok, value, rest} ->
            {:ok, value, %{s | tail: rest}}
          {:error, :incomplete} ->
            wait_for_response(%{s | tail: data})
        end
      {:error, _} = err ->
        err
    end
  end
end