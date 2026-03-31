defmodule WCore.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use WCore.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias WCore.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import WCore.DataCase
    end
  end

  setup tags do
    WCore.DataCase.setup_sandbox(tags)

    # Limpa entradas de teste do ETS entre os testes para evitar vazamento de estado.
    # Usamos IDs altos (>= 900_000) nos testes para não colidir com dados de dev.
    on_exit(fn ->
      if :ets.info(:w_core_telemetry_cache) != :undefined do
        :ets.match_delete(:w_core_telemetry_cache, {:"$1", :_, :_, :_, :_})
      end
    end)

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(WCore.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
