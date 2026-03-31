defmodule WCore.Telemetry.WriteBehindWorker do
  @moduledoc """
  Worker responsável por sincronizar o estado do ETS com o SQLite.

  ## Estratégia de flush híbrida
  - **Timer-based (primário):** flush a cada @flush_interval_ms (padrão 5s)
  - **Threshold-based (secundário):** flush antecipado se @dirty_threshold
    eventos se acumularem antes do timer disparar

  Isso garante latência de persistência previsível (max 5s) em carga normal,
  e flush antecipado durante picos (ex: 10k eventos em 1s).

  ## Por que não ler o ETS diretamente para contar eventos sujos?
  Rastrear o dirty_count no estado deste GenServer evita ter que varrer o ETS
  inteiro apenas para saber SE há algo para persistir. O custo é um cast a mais
  por heartbeat, mas o ganho é evitar O(n) scans desnecessários.
  """

  use GenServer
  require Logger

  alias WCore.Telemetry
  alias WCore.Telemetry.TelemetryServer

  @flush_interval_ms Application.compile_env(:w_core, :write_behind_interval_ms, 5_000)
  @dirty_threshold Application.compile_env(:w_core, :write_behind_dirty_threshold, 500)

  defstruct dirty_count: 0, timer_ref: nil

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Incrementa o contador de entradas sujas. Chamado pelo TelemetryServer a cada heartbeat."
  @spec mark_dirty() :: :ok
  def mark_dirty do
    GenServer.cast(__MODULE__, :mark_dirty)
  end

  @doc """
  Força um flush síncrono imediato. Usado nos testes de caos para garantir
  que o estado do SQLite seja verificável de forma determinística.
  """
  @spec flush_now() :: :ok | :error
  def flush_now do
    GenServer.call(__MODULE__, :flush_now, 30_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    timer_ref = schedule_flush()
    {:ok, %__MODULE__{timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast(:mark_dirty, %{dirty_count: count} = state) do
    new_count = count + 1

    if new_count >= @dirty_threshold do
      # Flush antecipado: cancela o timer atual e persiste agora
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      do_flush()
      {:noreply, %{state | dirty_count: 0, timer_ref: schedule_flush()}}
    else
      {:noreply, %{state | dirty_count: new_count}}
    end
  end

  @impl true
  def handle_call(:flush_now, _from, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    result = do_flush()
    {:reply, result, %{state | dirty_count: 0, timer_ref: schedule_flush()}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    {:noreply, %{state | dirty_count: 0, timer_ref: schedule_flush()}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp do_flush do
    try do
      do_flush_unsafe()
    catch
      :exit, reason ->
        # Ocorre em testes quando o timer dispara após o dono da conexão
        # sandbox já ter saído. Seguro ignorar — o próximo ciclo tentará novamente.
        Logger.debug("[WriteBehindWorker] Flush skipped (connection exit): #{inspect(reason)}")
        :ok
    end
  end

  defp do_flush_unsafe do
    entries = TelemetryServer.all_node_states()

    if entries == [] do
      :ok
    else
      # Filtra apenas node_ids que existem no banco.
      # Isso garante que entradas "quentes" no ETS que ainda não têm registro
      # em nodes (ex: inserções diretas em testes) não causem FK constraint errors.
      # Custo: 1 SELECT por ciclo de flush (a cada 5s) — totalmente aceitável.
      import Ecto.Query
      valid_ids =
        WCore.Repo.all(from n in WCore.Telemetry.Node, select: n.id)
        |> MapSet.new()

      metrics =
        entries
        |> Enum.filter(fn {node_id, _, _, _, _} -> MapSet.member?(valid_ids, node_id) end)
        |> Enum.map(fn {node_id, status, count, payload, ts} ->
          %{
            node_id: node_id,
            status: status,
            total_events_processed: count,
            last_payload: payload,
            last_seen_at: ts
          }
        end)

      case Telemetry.batch_upsert_metrics(Enum.to_list(metrics)) do
        {:ok, n} ->
          Logger.debug("[WriteBehindWorker] Flushed #{n} node metrics to SQLite")

          # Tick periódico para LiveViews atualizarem contadores de eventos
          Phoenix.PubSub.broadcast(WCore.PubSub, "telemetry:updates", :dashboard_tick)

          :ok

        {:error, reason} ->
          Logger.error("[WriteBehindWorker] Flush failed: #{inspect(reason)}")
          :error
      end
    end
  end
end
