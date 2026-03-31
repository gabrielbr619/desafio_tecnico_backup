defmodule WCoreWeb.HealthController do
  use WCoreWeb, :controller

  def index(conn, _params) do
    ets_ok = :ets.info(:w_core_telemetry_cache) != :undefined

    json(conn, %{
      status: "ok",
      ets: ets_ok,
      timestamp: DateTime.utc_now()
    })
  end
end
