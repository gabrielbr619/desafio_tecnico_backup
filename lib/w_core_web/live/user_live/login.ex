defmodule WCoreWeb.UserLive.Login do
  use WCoreWeb, :live_view

  alias WCore.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="auth-form">
        <div class="auth-form__header">
          <h1 class="auth-form__title">Entrar</h1>
          <p class="auth-form__subtitle">
            <%= if @current_scope do %>
              Confirme sua identidade para continuar.
            <% else %>
              Não tem uma conta?
              <.link navigate={~p"/users/register"} class="auth-form__link">
                Criar conta
              </.link>
            <% end %>
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="auth-info-box">
          <.icon name="hero-information-circle" class="size-4 shrink-0 text-sky-400" />
          <span>
            Rodando com adaptador local de e-mail.
            <.link href="/dev/mailbox" class="auth-form__link">Ver caixa de entrada</.link>
          </span>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <p class="auth-form__section-label">Entrar com link mágico</p>
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="auth-btn auth-btn--primary auth-btn--full">
            Enviar link de acesso
          </.button>
        </.form>

        <div class="auth-divider"><span>ou</span></div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <p class="auth-form__section-label">Entrar com senha</p>
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Senha"
            autocomplete="current-password"
            spellcheck="false"
          />
          <div class="auth-btn-group">
            <.button class="auth-btn auth-btn--primary auth-btn--full" name={@form[:remember_me].name} value="true">
              Entrar e manter conectado
            </.button>
            <.button class="auth-btn auth-btn--ghost auth-btn--full">
              Entrar apenas desta vez
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info = "Se o e-mail estiver cadastrado, você receberá um link de acesso em instantes."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:w_core, WCore.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
