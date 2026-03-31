defmodule WCoreWeb.TelemetryComponents do
  @moduledoc """
  Design System da Planta 42.

  Componentes HEEx puros criados do zero para o dashboard de telemetria.
  Sem bibliotecas pesadas de UI — apenas componentes de função com HEEx
  e classes CSS customizadas.

  Componentes disponíveis:
    - <.status_badge status="online" />
    - <.node_card node={node} />
    - <.stats_bar stats={stats} />
    - <.search_input value="" />
    - <.filter_bar active="all" counts={counts} />
    - <.empty_state type={:no_nodes | :no_results} />
    - <.timeline events={events} />
    - <.payload_history logs={logs} />
    - <.node_detail_header node={node} db_node={db_node} />
  """

  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # StatusBadge
  # ---------------------------------------------------------------------------

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge", badge_class(@status)]}>
      <span class={["badge__dot", dot_class(@status)]}></span>
      <%= String.upcase(@status) %>
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # NodeCard
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true

  def node_card(assigns) do
    ~H"""
    <div class={["node-card", node_card_class(@node.status)]} id={"node-#{@node.id}"}>
      <div class="node-card__header">
        <span class="node-card__id">
          <.link navigate={"/nodes/#{@node.id}"} class="hover:text-white transition-colors">
            Nó #<%= @node.id %>
          </.link>
        </span>
        <.status_badge status={@node.status} />
      </div>

      <div class="node-card__metrics">
        <div class="node-card__metric">
          <span class="node-card__metric-label">Eventos</span>
          <span class="node-card__metric-value"><%= format_number(@node.event_count) %></span>
        </div>
        <div class="node-card__metric">
          <span class="node-card__metric-label">Último sinal</span>
          <span class="node-card__metric-value text-xs"><%= format_ts(@node.last_seen_at) %></span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # StatsBar
  # ---------------------------------------------------------------------------

  attr :stats, :map, required: true

  def stats_bar(assigns) do
    ~H"""
    <div class="stats-bar">
      <.stat_item label="Total de Nós" value={@stats.total} color="text-gray-200" />
      <div class="stats-bar__divider"></div>
      <.stat_item label="Online" value={@stats.online} color="text-emerald-400" />
      <.stat_item label="Degradado" value={@stats.degraded} color="text-amber-400" />
      <.stat_item label="Offline" value={@stats.offline} color="text-red-400" />
      <div class="stats-bar__divider"></div>
      <.stat_item label="Total de Eventos" value={format_number(@stats.total_events)} color="text-sky-400" />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # SearchInput
  # ---------------------------------------------------------------------------

  attr :value, :string, default: ""

  def search_input(assigns) do
    ~H"""
    <div class="search-input">
      <svg class="search-input__icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor">
        <path fill-rule="evenodd" d="M9 3.5a5.5 5.5 0 100 11 5.5 5.5 0 000-11zM2 9a7 7 0 1112.452 4.391l3.328 3.329a.75.75 0 11-1.06 1.06l-3.329-3.328A7 7 0 012 9z" clip-rule="evenodd" />
      </svg>
      <input
        type="text"
        placeholder="Buscar por ID ou identificador..."
        value={@value}
        phx-change="search"
        phx-debounce="300"
        name="query"
        class="search-input__field"
        autocomplete="off"
      />
      <%= if @value != "" do %>
        <button phx-click="clear_search" class="search-input__clear" type="button">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
            <path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />
          </svg>
        </button>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # FilterBar
  # ---------------------------------------------------------------------------

  attr :active, :string, default: "all"
  attr :counts, :map, required: true

  def filter_bar(assigns) do
    ~H"""
    <div class="filter-bar">
      <button
        :for={{label, value, color} <- filter_options()}
        phx-click="filter"
        phx-value-status={value}
        class={["filter-bar__btn", filter_btn_active(@active, value), color]}
      >
        <%= label %>
        <span class="filter-bar__count"><%= Map.get(@counts, value, 0) %></span>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # SortHeader
  # ---------------------------------------------------------------------------

  attr :current_sort, :string, default: "id"
  attr :current_dir, :string, default: "asc"

  def sort_controls(assigns) do
    ~H"""
    <div class="sort-controls">
      <span class="sort-controls__label">Ordenar por:</span>
      <button
        :for={{label, field} <- sort_options()}
        phx-click="sort"
        phx-value-field={field}
        class={["sort-controls__btn", sort_btn_active(@current_sort, field)]}
      >
        <%= label %>
        <%= if @current_sort == field do %>
          <span class="sort-controls__arrow"><%= if @current_dir == "asc", do: "↑", else: "↓" %></span>
        <% end %>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # EmptyState
  # ---------------------------------------------------------------------------

  attr :type, :atom, default: :no_nodes

  def empty_state(assigns) do
    ~H"""
    <div class="empty-state">
      <%= if @type == :no_nodes do %>
        <div class="empty-state__icon">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1" stroke="currentColor" class="w-16 h-16">
            <path stroke-linecap="round" stroke-linejoin="round" d="M8.288 15.038a5.25 5.25 0 0 1 7.424 0M5.106 11.856c3.807-3.808 9.98-3.808 13.788 0M1.924 8.674c5.565-5.565 14.587-5.565 20.152 0M12.53 18.22l-.53.53-.53-.53a.75.75 0 0 1 1.06 0Z" />
          </svg>
        </div>
        <h3 class="empty-state__title">Nenhum sensor registrado</h3>
        <p class="empty-state__description">
          Envie o primeiro heartbeat para começar a monitorar.
        </p>
        <div class="empty-state__code">
          <code>POST /api/v1/heartbeat</code>
        </div>
      <% else %>
        <div class="empty-state__icon empty-state__icon--muted">
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1" stroke="currentColor" class="w-12 h-12">
            <path stroke-linecap="round" stroke-linejoin="round" d="m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z" />
          </svg>
        </div>
        <h3 class="empty-state__title empty-state__title--sm">Nenhum resultado encontrado</h3>
        <p class="empty-state__description">Tente ajustar os filtros ou a busca.</p>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Timeline (status events history)
  # ---------------------------------------------------------------------------

  attr :events, :list, required: true

  def timeline(assigns) do
    ~H"""
    <div class="timeline">
      <h3 class="timeline__title">Histórico de Status</h3>
      <%= if @events == [] do %>
        <p class="timeline__empty">Nenhuma mudança de status registrada.</p>
      <% else %>
        <div class="timeline__list">
          <div :for={event <- @events} class="timeline__item">
            <div class="timeline__transition">
              <%= if event.from_status do %>
                <.status_badge status={event.from_status} />
                <span class="timeline__arrow">→</span>
              <% end %>
              <.status_badge status={event.to_status} />
            </div>
            <time class="timeline__time"><%= format_datetime(event.recorded_at) %></time>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # PayloadHistory
  # ---------------------------------------------------------------------------

  attr :logs, :list, required: true

  def payload_history(assigns) do
    ~H"""
    <div class="payload-history">
      <h3 class="payload-history__title">
        Histórico de Payloads
        <span class="payload-history__count"><%= length(@logs) %></span>
      </h3>
      <%= if @logs == [] do %>
        <p class="payload-history__empty">Nenhum payload registrado ainda.</p>
      <% else %>
        <div class="payload-history__list">
          <%= for {log, i} <- Enum.with_index(@logs) do %>
            <details class={["payload-history__item", i == 0 && "payload-history__item--latest"]} {if i == 0, do: [open: true], else: []}>
              <summary class="payload-history__summary">
                <span class="payload-history__summary-left">
                  <.status_badge status={log.status} />
                  <time class="payload-history__ts"><%= format_datetime(log.inserted_at) %></time>
                </span>
                <span class="payload-history__chevron">▾</span>
              </summary>
              <pre class="payload-history__pre"><%= format_payload_pretty(log.payload) %></pre>
            </details>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # NodeDetailHeader
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :db_node, :map, default: nil

  def node_detail_header(assigns) do
    ~H"""
    <div class="node-detail-header">
      <div class="node-detail-header__top">
        <div>
          <h1 class="node-detail-header__title">Nó #<%= @node.id %></h1>
          <%= if @db_node do %>
            <p class="node-detail-header__identifier"><%= @db_node.machine_identifier %></p>
          <% end %>
        </div>
        <.status_badge status={@node.status} />
      </div>

      <div class="node-detail-header__stats">
        <div class="node-detail-header__stat">
          <span class="node-detail-header__stat-label">Total de Eventos</span>
          <span class="node-detail-header__stat-value text-sky-400"><%= format_number(@node.event_count) %></span>
        </div>
        <div class="node-detail-header__stat">
          <span class="node-detail-header__stat-label">Último Sinal</span>
          <span class="node-detail-header__stat-value"><%= format_datetime(@node.last_seen_at) %></span>
        </div>
        <%= if @db_node && @db_node.location do %>
          <div class="node-detail-header__stat">
            <span class="node-detail-header__stat-label">Localização</span>
            <span class="node-detail-header__stat-value"><%= @db_node.location %></span>
          </div>
        <% end %>
        <%= if @db_node do %>
          <div class="node-detail-header__stat">
            <span class="node-detail-header__stat-label">Registrado em</span>
            <span class="node-detail-header__stat-value"><%= format_date(@db_node.inserted_at) %></span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private: stat_item (used by stats_bar)
  # ---------------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "text-white"

  defp stat_item(assigns) do
    ~H"""
    <div class="stat-item">
      <span class="stat-item__label"><%= @label %></span>
      <span class={["stat-item__value", @color]}><%= @value %></span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp badge_class("online"), do: "badge--online"
  defp badge_class("offline"), do: "badge--offline"
  defp badge_class("degraded"), do: "badge--degraded"
  defp badge_class(_), do: "badge--unknown"

  defp dot_class("online"), do: "badge__dot--pulse"
  defp dot_class(_), do: ""

  defp node_card_class("online"), do: "node-card--online"
  defp node_card_class("offline"), do: "node-card--offline"
  defp node_card_class("degraded"), do: "node-card--degraded"
  defp node_card_class(_), do: "node-card--unknown"

  defp filter_options do
    [
      {"Todos", "all", ""},
      {"Online", "online", "filter-bar__btn--online"},
      {"Degradado", "degraded", "filter-bar__btn--degraded"},
      {"Offline", "offline", "filter-bar__btn--offline"}
    ]
  end

  defp filter_btn_active(active, value) when active == value, do: "filter-bar__btn--active"
  defp filter_btn_active(_, _), do: ""

  defp sort_options do
    [
      {"ID", "id"},
      {"Status", "status"},
      {"Eventos", "events"},
      {"Último sinal", "last_seen"}
    ]
  end

  defp sort_btn_active(current, field) when current == field, do: "sort-controls__btn--active"
  defp sort_btn_active(_, _), do: ""

  # Brasil = UTC-3, sem horário de verão desde 2019
  @utc_offset_seconds -3 * 3600

  defp to_brt(%DateTime{} = dt), do: DateTime.add(dt, @utc_offset_seconds)
  defp to_brt(%NaiveDateTime{} = dt), do: NaiveDateTime.add(dt, @utc_offset_seconds)

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: dt |> to_brt() |> Calendar.strftime("%H:%M:%S")
  defp format_ts(_), do: "—"

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: dt |> to_brt() |> Calendar.strftime("%d/%m %H:%M:%S")
  defp format_datetime(_), do: "—"

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: dt |> to_brt() |> Calendar.strftime("%d/%m/%Y")
  defp format_date(%NaiveDateTime{} = dt), do: dt |> to_brt() |> Calendar.strftime("%d/%m/%Y")
  defp format_date(_), do: "—"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(".")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp format_payload_pretty(nil), do: "{}"
  defp format_payload_pretty(""), do: "{}"

  defp format_payload_pretty(payload_str) do
    case Jason.decode(payload_str) do
      {:ok, map} -> Jason.encode!(map, pretty: true)
      _ -> payload_str
    end
  end
end
