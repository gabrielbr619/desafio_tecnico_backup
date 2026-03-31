defmodule WCoreWeb.ApiAuthPlug do
  @moduledoc """
  Simple Bearer token authentication for the heartbeat API.
  The expected token is configured via the :api_key application env,
  set from the API_KEY environment variable in production.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:w_core, :api_key)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == expected ->
        conn

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
