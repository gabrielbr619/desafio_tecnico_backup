defmodule WCoreWeb.DashboardLive do
  @moduledoc """
  Sala de Controle da Planta 42.

  Lê o estado dos nós diretamente do ETS (camada quente) no mount e
  mantém o dashboard atualizado via dois tipos de mensagem PubSub:

  - {:status_change, node_id, status, ts} — atualização cirúrgica: muta
    apenas o nó afetado, sem re-renderizar o grid inteiro.

  - :dashboard_tick — disparo periódico do WriteBehindWorker após cada flush
    (a cada 5s). Faz reload completo do ETS para refletir contadores atualizados.
  """

  use WCoreWeb, :live_view

  alias WCore.Telemetry.TelemetryServer
  import WCoreWeb.TelemetryComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(WCore.PubSub, "telemetry:updates")
    end

    nodes = load_nodes_from_ets()

    {:ok,
     assign(socket,
       all_nodes: nodes,
       nodes: nodes,
       stats: compute_stats(nodes),
       last_updated: DateTime.utc_now(),
       page_title: "Sala de Controle — Planta 42",
       search: "",
       filter: "all",
       sort_field: "id",
       sort_dir: "asc"
     )}
  end

  @impl true
  def handle_info({:status_change, node_id, new_status, timestamp}, socket) do
    updated_all =
      Enum.map(socket.assigns.all_nodes, fn node ->
        if node.id == node_id do
          # Lê do ETS pra pegar o event_count atualizado junto com a mudança de status
          case TelemetryServer.get_node_state(node_id) do
            {:ok, {_, status, count, _, ts}} ->
              %{node | status: status, event_count: count, last_seen_at: ts}

            :not_found ->
              %{node | status: new_status, last_seen_at: timestamp}
          end
        else
          node
        end
      end)

    {:noreply,
     socket
     |> assign(all_nodes: updated_all)
     |> apply_filters_and_sort()}
  end

  def handle_info(:dashboard_tick, socket) do
    nodes = load_nodes_from_ets()

    {:noreply,
     socket
     |> assign(all_nodes: nodes, last_updated: DateTime.utc_now())
     |> apply_filters_and_sort()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(search: query)
     |> apply_filters_and_sort()}
  end

  def handle_event("clear_search", _, socket) do
    {:noreply,
     socket
     |> assign(search: "")
     |> apply_filters_and_sort()}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(filter: status)
     |> apply_filters_and_sort()}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_field == field do
        if socket.assigns.sort_dir == "asc", do: "desc", else: "asc"
      else
        "asc"
      end

    {:noreply,
     socket
     |> assign(sort_field: field, sort_dir: dir)
     |> apply_filters_and_sort()}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <header class="border-b border-gray-800 px-6 py-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold text-white tracking-tight">
              W-Core
              <span class="text-gray-500 font-normal text-sm ml-2">/ Sala de Controle</span>
            </h1>
            <p class="text-xs text-gray-500 mt-0.5">Planta 42 — Motor de Estado em Tempo Real</p>
          </div>
          <div class="text-xs text-gray-600">
            Atualizado: <%= format_ts(@last_updated) %>
          </div>
        </div>
      </header>

      <main class="px-6 py-6">
        <.stats_bar stats={@stats} />

        <div class="dashboard-controls">
          <.search_input value={@search} />
          <.filter_bar active={@filter} counts={filter_counts(@all_nodes)} />
          <.sort_controls current_sort={@sort_field} current_dir={@sort_dir} />
        </div>

        <%= if @all_nodes == [] do %>
          <.empty_state type={:no_nodes} />
        <% else %>
          <%= if @nodes == [] do %>
            <.empty_state type={:no_results} />
          <% else %>
            <div class="dashboard-results-info">
              Mostrando <%= length(@nodes) %> de <%= length(@all_nodes) %> nós
            </div>
            <div class="node-grid">
              <.node_card :for={node <- @nodes} node={node} />
            </div>
          <% end %>
        <% end %>
      </main>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp apply_filters_and_sort(socket) do
    nodes =
      socket.assigns.all_nodes
      |> filter_by_status(socket.assigns.filter)
      |> filter_by_search(socket.assigns.search)
      |> sort_nodes(socket.assigns.sort_field, socket.assigns.sort_dir)

    assign(socket,
      nodes: nodes,
      stats: compute_stats(socket.assigns.all_nodes)
    )
  end

  defp filter_by_status(nodes, "all"), do: nodes
  defp filter_by_status(nodes, status), do: Enum.filter(nodes, &(&1.status == status))

  defp filter_by_search(nodes, ""), do: nodes

  defp filter_by_search(nodes, query) do
    q = String.downcase(query)

    Enum.filter(nodes, fn node ->
      String.contains?(Integer.to_string(node.id), q)
    end)
  end

  defp sort_nodes(nodes, field, dir) do
    sorter =
      case field do
        "id" -> &(&1.id)
        "status" -> &status_order(&1.status)
        "events" -> &(&1.event_count)
        "last_seen" -> &(&1.last_seen_at)
        _ -> &(&1.id)
      end

    sorted = Enum.sort_by(nodes, sorter)
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp status_order("online"), do: 0
  defp status_order("degraded"), do: 1
  defp status_order("offline"), do: 2
  defp status_order(_), do: 3

  defp filter_counts(nodes) do
    %{
      "all" => length(nodes),
      "online" => Enum.count(nodes, &(&1.status == "online")),
      "degraded" => Enum.count(nodes, &(&1.status == "degraded")),
      "offline" => Enum.count(nodes, &(&1.status == "offline"))
    }
  end

  defp load_nodes_from_ets do
    TelemetryServer.all_node_states()
    |> Enum.map(fn {node_id, status, event_count, last_payload, last_seen_at} ->
      %{
        id: node_id,
        status: status,
        event_count: event_count,
        last_payload: last_payload,
        last_seen_at: last_seen_at
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp compute_stats(nodes) do
    total = length(nodes)
    online = Enum.count(nodes, &(&1.status == "online"))
    degraded = Enum.count(nodes, &(&1.status == "degraded"))
    offline = Enum.count(nodes, &(&1.status == "offline"))
    total_events = Enum.sum(Enum.map(nodes, & &1.event_count))

    %{
      total: total,
      online: online,
      degraded: degraded,
      offline: offline,
      total_events: total_events
    }
  end

  defp format_ts(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end
end
