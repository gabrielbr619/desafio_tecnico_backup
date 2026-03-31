defmodule WCore.Telemetry.Supervisor do
  @moduledoc """
  Supervisor da camada de ingestão de telemetria.

  ## Estratégia: :rest_for_one

  TelemetryServer deve ser iniciado ANTES do WriteBehindWorker porque:
  1. TelemetryServer.init/1 cria a tabela ETS :w_core_telemetry_cache
  2. WriteBehindWorker.do_flush/0 chama TelemetryServer.all_node_states/0
     que lê diretamente o ETS

  Com :rest_for_one, se TelemetryServer crashar:
  - TelemetryServer reinicia (recria o ETS vazio + warm-up do SQLite)
  - WriteBehindWorker também reinicia (reseta o timer e dirty_count)

  Isso evita que WriteBehindWorker fique rodando com um timer apontando
  para uma tabela ETS que não existe mais, o que causaria erros de :badarg
  no próximo ciclo de flush.

  Se WriteBehindWorker crashar isoladamente (ex: SQLite temporariamente
  indisponível), apenas ele reinicia — TelemetryServer e o ETS ficam intactos,
  sem perda de dados em memória.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      WCore.Telemetry.TelemetryServer,
      WCore.Telemetry.WriteBehindWorker
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
