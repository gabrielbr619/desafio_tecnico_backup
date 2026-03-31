defmodule WCoreWeb.Plugs.MailboxStyleInjector do
  @moduledoc """
  Injects design system CSS overrides into the Swoosh mailbox preview HTML.

  Plug.Swoosh.MailboxPreview renders its own complete HTML with Tailwind CSS,
  so we can't wrap it in our layout. Instead, we intercept the response body
  and inject a <style> block that overrides the Tailwind dark mode colors to
  match our design system.
  """

  @behaviour Plug

  @css_overrides """
  <style>
    /* W-Core design system overrides for Swoosh mailbox */

    /* Main background */
    html.dark body {
      background-color: rgb(3 7 18) !important;
      color: rgb(248 250 252) !important;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
    }

    /* Sidebar */
    html.dark .dark\:bg-gray-900 { background-color: rgb(3 7 18) !important; }
    html.dark .dark\:border-gray-700 { border-color: rgb(30 41 59) !important; }
    html.dark .dark\:bg-gray-800 {
      background-color: rgb(15 23 42) !important;
      border-left: 2px solid rgb(79 70 229);
    }

    /* Sidebar header */
    html.dark h1 { color: rgb(248 250 252); }
    html.dark .dark\:text-gray-500 { color: rgb(100 116 139) !important; }

    /* Email list items */
    html.dark a { color: inherit; }
    html.dark a:hover { background-color: rgb(15 23 42) !important; }

    /* Text colors */
    html.dark .dark\:text-white { color: rgb(248 250 252) !important; }
    html.dark .dark\:text-gray-100 { color: rgb(226 232 240) !important; }
    html.dark .dark\:text-gray-300 { color: rgb(148 163 184) !important; }

    /* Dividers */
    html.dark .dark\:divide-gray-700 > * + * { border-color: rgb(30 41 59) !important; }

    /* "Limpar caixa" button → indigo accent matching auth-btn--primary */
    .bg-blue-500 {
      display: inline-flex !important;
      align-items: center !important;
      justify-content: center !important;
      background: rgb(79 70 229) !important;
      border: 1px solid rgb(79 70 229) !important;
      color: white !important;
      font-size: 0.8125rem !important;
      font-weight: 500 !important;
      padding: 0.5625rem 1rem !important;
      border-radius: 0.5rem !important;
      cursor: pointer !important;
      transition: all 0.15s ease !important;
      text-decoration: none !important;
      letter-spacing: normal !important;
    }
    .bg-blue-500:hover,
    .hover\:bg-blue-400:hover {
      background: rgb(99 102 241) !important;
      border-color: rgb(99 102 241) !important;
    }

    /* No-email empty state */
    html.dark .text-gray-400 { color: rgb(71 85 105) !important; }
    html.dark .text-gray-700 { color: rgb(148 163 184) !important; }

    /* Scroll bar (webkit) */
    html.dark ::-webkit-scrollbar { width: 6px; height: 6px; }
    html.dark ::-webkit-scrollbar-track { background: rgb(3 7 18); }
    html.dark ::-webkit-scrollbar-thumb {
      background: rgb(30 41 59);
      border-radius: 3px;
    }
    html.dark ::-webkit-scrollbar-thumb:hover { background: rgb(51 65 85); }

    /* Collapsible sections */
    html.dark summary { color: rgb(148 163 184); }
    html.dark details pre {
      background-color: rgb(15 23 42) !important;
      border: 1px solid rgb(30 41 59);
      border-radius: 6px;
      padding: 12px;
      color: rgb(226 232 240);
    }

    /* Iframe placeholder */
    html.dark iframe { border: 1px solid rgb(30 41 59) !important; border-radius: 4px; }

    /* Page title bar / top strip if any */
    html.dark .border-r { border-color: rgb(30 41 59) !important; }

    /* Adjust sidebar height to account for our injected nav (52px) */
    html.dark .h-screen { height: calc(100vh - 52px) !important; }
    html.dark body { overflow: hidden; }
    html.dark .flex { display: flex; }
  </style>
  """

  @impl Plug
  def init(opts), do: opts

  @translate_script """
  <script>
    document.addEventListener("DOMContentLoaded", function () {
      document.querySelectorAll("button[type='submit']").forEach(function (btn) {
        if (btn.textContent.trim() === "Empty mailbox") {
          btn.textContent = "Limpar caixa de entrada";
        }
      });
    });
  </script>
  """

  @nav_bar """
  <nav style="
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 20px;
    height: 52px;
    background: rgb(3 7 18);
    border-bottom: 1px solid rgb(30 41 59);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    position: sticky;
    top: 0;
    z-index: 100;
  ">
    <a href="/dashboard" style="
      color: rgb(248 250 252);
      font-size: 14px;
      font-weight: 600;
      text-decoration: none;
      letter-spacing: -0.01em;
    ">W-Core <span style="color: rgb(100 116 139); font-weight: 400;">/ Planta 42</span></a>
    <span style="
      color: rgb(100 116 139);
      font-size: 12px;
      font-weight: 500;
      letter-spacing: 0.05em;
      text-transform: uppercase;
    ">Dev Mailbox</span>
  </nav>
  """

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn conn ->
      content_type =
        conn
        |> Plug.Conn.get_resp_header("content-type")
        |> List.first("")

      if String.contains?(content_type, "text/html") do
        body = IO.iodata_to_binary(conn.resp_body)

        injected =
          body
          |> String.replace("</head>", @css_overrides <> @translate_script <> "\n  </head>", global: false)
          |> inject_nav_after_body_tag()

        %{conn | resp_body: injected}
      else
        conn
      end
    end)
  end

  defp inject_nav_after_body_tag(html) do
    case String.split(html, ~r/<body[^>]*>/, parts: 2, include_captures: true) do
      [before, tag, after_tag] -> before <> tag <> "\n" <> @nav_bar <> after_tag
      _ -> html
    end
  end
end
