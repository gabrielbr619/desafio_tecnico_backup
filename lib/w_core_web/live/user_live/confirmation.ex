defmodule WCoreWeb.UserLive.Confirmation do
  use WCoreWeb, :live_view

  alias WCore.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="auth-form">
        <div class="auth-form__header">
          <h1 class="auth-form__title">Bem-vindo!</h1>
          <p class="auth-form__subtitle">{@user.email}</p>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <div class="auth-btn-group">
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Confirmando..."
              class="auth-btn auth-btn--primary auth-btn--full"
            >
              Confirmar e manter conectado
            </.button>
            <.button phx-disable-with="Confirmando..." class="auth-btn auth-btn--ghost auth-btn--full">
              Confirmar e entrar só desta vez
            </.button>
          </div>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Entrando..." class="auth-btn auth-btn--primary auth-btn--full">
              Entrar
            </.button>
          <% else %>
            <div class="auth-btn-group">
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Entrando..."
                class="auth-btn auth-btn--primary auth-btn--full"
              >
                Manter conectado neste dispositivo
              </.button>
              <.button phx-disable-with="Entrando..." class="auth-btn auth-btn--ghost auth-btn--full">
                Entrar só desta vez
              </.button>
            </div>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="auth-tip">
          Dica: se preferir usar senha, você pode ativar nas configurações da conta.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Link de acesso inválido ou expirado.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
