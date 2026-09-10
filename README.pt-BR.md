# SQL Server Workload Telemetry

*[English version](README.md)*

Telemetria de workload para instâncias SQL Server **sem Query Store** — ou seja, qualquer coisa anterior ao SQL Server 2016, onde o ferramental usual simplesmente não existe.

Responde quatro perguntas sobre uma instância em produção:

- Quais queries mais executam, e quanto custam de CPU?
- Quanto tempo levam, incluindo a cauda (p95/p99) e não só a média?
- Quais jobs do Agent tocam um determinado banco, quanto tempo rodam, e **quais execuções de fato fizeram trabalho** em vez de terminar em 0 segundos por não haver nada a processar?
- Quais foram os valores reais de parâmetro, para derivar casos de teste replayáveis?

Construído para servir de baseline de migração, mas funciona como observabilidade de propósito geral numa instância legada.

## O que coleta

| Fluxo | Tabela | Conteúdo | Intervalo | Retenção padrão |
|---|---|---|---|---|
| Workload cru | `xe_workload` | Cada batch e RPC: texto completo do statement **com valores de parâmetro**, duração, CPU, leituras lógicas e físicas, escritas de I/O, contagem de linhas, app, host, login, sessão, e o job step de origem | 5 min | 30 dias |
| Estatísticas agregadas | `query_stat_delta` + `query_text` | Delta por intervalo de execuções, CPU, leituras e escritas por `query_hash` — o substituto do Query Store | 5 min | 90 dias |
| Execuções de job | `job_run`, view `vw_job_run_effective` | Duração real em segundos, status, flag de guard step, e `did_work` | 2 min | 365 dias |
| Amostragem de requisições ativas | `who_is_active` | Requisições longas, bloqueadas e bloqueantes | 1 min | 30 dias |

Mais o `collection_run`, trilha de auditoria de cada execução dos coletores. Essa importa mais do que parece: sem ela, um buraco nos dados é indistinguível de um coletor que morreu em silêncio.

**Qual tabela usar para quê:** o `query_stat_delta` diz *o que importa e quanto custa*; o `xe_workload` guarda *o texto completo com os valores reais*. O `query_text` é dimensão de rotulagem, truncada em 4.000 caracteres — não é fonte de query na íntegra.

## Requisitos

- SQL Server 2014 ou superior. Escrito contra o 2014, portanto evita `CREATE OR ALTER`, `AT TIME ZONE`, `STRING_AGG` e Query Store em todo o código.
- `sysadmin`, ou permissão suficiente para criar banco, event session e jobs do Agent.
- [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) instalado no `master`. Não é redistribuído aqui; instale antes.
- Um diretório com permissão de escrita para os arquivos de rollover do Extended Events, de preferência fora do volume de dados e de log.
- `sqlcmd`, ou SSMS com o **SQLCMD Mode** habilitado. Os scripts usam `:setvar`, que o SSMS comum não expande.

## Instalação

```bash
cp config.example.sql config.sql
# edite config.sql: nomes de banco, caminho do .xel, dono dos jobs
sqlcmd -S <servidor> -E -I -b -i deploy.sql
```

O `-I` é obrigatório — vários scripts usam métodos de XML, que exigem `QUOTED_IDENTIFIER ON`. O `-b` aborta no primeiro erro. Rode a partir da raiz do repositório, porque o `:r` resolve caminho relativo ao diretório de trabalho.

A sessão de captura é criada mas **não é iniciada**, então nada é gravado até você mandar:

```sql
ALTER EVENT SESSION [Workload_Capture] ON SERVER STATE = START;
```

Depois espere alguns minutos e rode a query 1 do [`queries/consumption.sql`](queries/consumption.sql) para confirmar que todos os coletores estão rodando limpos.

Rodar o `deploy.sql` de novo é seguro. Procedures e jobs são recriados no lugar; dado coletado nunca é tocado.

### Em Availability Group

Instale em **todas as réplicas**, não só na primária atual. Event sessions têm escopo de servidor, não de AG — uma sessão que existe só num nó para de coletar no instante em que ocorre um failover, e em silêncio.

O banco de telemetria fica deliberadamente **fora** do AG: dado de monitoramento não deve depender do que ele monitora, e um banco dentro do AG fica read-only no secundário, o que impediria um coletor de lá de escrever qualquer coisa. Cada nó tem a sua cópia; a coluna `node_name` identifica a origem.

Pelo mesmo motivo, os jobs criados aqui **não têm guard de réplica**. Um guard faria o secundário nunca coletar nada.

## Dimensionamento

Medido numa instância de carga moderada: cerca de **12 eventos/segundo**, aproximadamente **750 bytes por linha armazenada**, o que deu por volta de **28 GB** em regime com a retenção padrão. Seu caso vai divergir em uma ordem de magnitude para cima ou para baixo, então calcule você mesmo: rode as queries 1 e 10 depois de uma semana e divida.

O file target do `.xel` tem teto definido na configuração (padrão 512 MB × 20 arquivos = 10 GB) e não passa disso. O histórico de longo prazo vive nas tabelas, não nos arquivos.

## Sensibilidade do dado

O `xe_workload.statement_text` contém **valores reais de parâmetro do servidor monitorado**. Trate essa tabela como dado de produção, possivelmente com dado pessoal.

- Não commite extrações dela. O `.gitignore` já exclui `*.csv`, `*.tsv` e `*.xel`.
- Tokenize antes de tirar do servidor, inclusive ao derivar uma suíte de benchmark a partir dela.
- Se isso for inaceitável no seu ambiente, coloque `collect_statement = 0` no `rpc_completed` em [`install/04_xevent_session.sql`](install/04_xevent_session.sql). Você mantém os tempos e os contadores de I/O, e perde a replayabilidade.

## Desinstalação

```bash
sqlcmd -S <servidor> -E -I -b -v Confirm="YES" -i uninstall/99_teardown.sql
```

Remove a event session, os jobs do Agent e o banco de telemetria. Os arquivos `.xel` precisam ser apagados no sistema operacional depois — T-SQL não remove arquivo sem habilitar `xp_cmdshell`, o que esta ferramenta não faz. O `sp_WhoIsActive` é deixado no lugar, já que era pré-requisito e não algo instalado aqui.

## Leia isto antes de mexer nos filtros

Três decisões de filtro em [`install/04_xevent_session.sql`](install/04_xevent_session.sql) parecem otimização óbvia e não são. Cada uma está documentada no próprio script e em [`docs/design-notes.pt-BR.md`](docs/design-notes.pt-BR.md):

1. **Não adicione filtro positivo de banco.** Em Extended Events, `database_id` é o *contexto da sessão*, não o objeto tocado. Um job step que roda em `master` e alcança seu banco por nome de três partes reporta `database_id = 1` e seria descartado — sem erro e sem aviso.
2. **msdb é a única exclusão**, porque é majoritariamente o Agent conversando consigo mesmo, mais um leitor de fila do Service Broker estacionado por minutos que arruína qualquer cálculo de percentil.
3. **Não filtre por `writes = 0`.** O `writes` conta *páginas* de I/O, não linhas. Statements que modificam páginas já em cache reportam zero. Filtrar por isso descarta a maior parte do trabalho real.

## Organização

```
config.example.sql      copie para config.sql e edite
deploy.sql              roda todos os scripts de instalação em ordem
install/                01 schema · 02 coletores · 03 who_is_active
                        04 event session · 05 jobs do Agent · 06 retenção
uninstall/99_teardown   remove tudo (com guarda de confirmação)
queries/consumption.sql 10 queries para ler os dados
docs/design-notes*.md   as armadilhas, e por que o desenho é o que é
```

## Licença

MIT. Veja [LICENSE](LICENSE).
