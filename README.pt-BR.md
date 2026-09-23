# SQL Server Workload Telemetry

*[English version](README.md)*

Telemetria de workload para instâncias SQL Server **sem Query Store** — ou seja, qualquer coisa anterior ao SQL Server 2016, onde o ferramental usual simplesmente não existe.

Responde quatro perguntas sobre uma instância em produção:

- Quais queries mais executam, e quanto custam de CPU?
- Quanto tempo levam, incluindo a cauda (p95/p99) e não só a média?
- Quais jobs do Agent tocam um determinado banco, quanto tempo rodam, e **quais execuções de fato fizeram trabalho** em vez de terminar em 0 segundos por não haver nada a processar?
- Quais foram os valores reais de parâmetro, para derivar casos de teste replayáveis?

Construído para servir de baseline de migração, mas funciona como observabilidade de propósito geral numa instância legada.

> **Antes de rodar: isto captura valores reais de parâmetro.**
> O `xe_workload.statement_text` vai conter dado real das suas queries de produção — nomes de cliente, identificadores, o que sua aplicação passar como parâmetro. Isso é deliberado, porque caso de teste replayável precisa de valor real, mas significa que a tabela é dado de produção e possivelmente dado pessoal. Leia [Sensibilidade do dado](#sensibilidade-do-dado) antes de instalar, e coloque `collect_statement = 0` se essa troca não for aceitável no seu ambiente.

## Alcance e ressalvas

Sendo honesto sobre a procedência: isto foi construído e medido contra **uma** instância SQL Server 2014 SP3 Enterprise, sob carga OLTP moderada. Funciona, e todas as decisões de desenho têm medição por trás — mas essas medições vêm daquela única instância.

Trate como ponto de partida, não como verdade universal:

- **Os intervalos de coleta.** O intervalo de 2 minutos para job runs existe porque o `sysjobhistory` daquela instância guardava cerca de 11 minutos de histórico para o job mais frequente dela. O seu pode guardar horas, ou minutos.
- **Os defaults de retenção e os números de dimensionamento.** Taxa de eventos varia em ordens de magnitude entre instâncias. Calcule a sua com as queries 1 e 10 depois de uma semana.
- **A detecção de guard step.** Desligada por padrão; precisa do padrão que os seus jobs usam.
- **O filtro de ruído do `who_is_active`.** As exclusões de `background`/`dormant`/DatabaseMail valeram naquela instância. Verifique o que as suas amostras realmente contêm antes de confiar no filtro.

O que generaliza sem ressalva é a lista de modos de falha em [`docs/design-notes.pt-BR.md`](docs/design-notes.pt-BR.md). Aquilo são propriedades do SQL Server, não de uma instância específica, e a maioria falha em silêncio.

## O que coleta

| Fluxo | Tabela | Conteúdo | Intervalo | Retenção padrão |
|---|---|---|---|---|
| Workload cru | `xe_workload` | Cada batch e RPC: texto completo do statement **com valores de parâmetro**, duração, CPU, leituras lógicas e físicas, escritas de I/O, contagem de linhas, app, host, login, sessão, e o job step de origem | 5 min | 30 dias |
| Estatísticas agregadas | `query_stat_delta` + `query_text` | Delta por intervalo de execuções, CPU, leituras e escritas por `query_hash` — o substituto do Query Store | 5 min | 90 dias |
| Execuções de job | `job_run`, view `vw_job_run_effective` | Duração real em segundos, status, flag de guard step, e `did_work` | 2 min | 365 dias |
| Amostragem de requisições ativas | `who_is_active`, view `vw_who_is_active` | Requisições longas, bloqueadas e bloqueantes. Leia pela view: o `sp_WhoIsActive` grava o timestamp em hora **local do servidor**, e a view acrescenta o equivalente em UTC | 1 min | 30 dias |
| Valores de parâmetro | `param_sample` | Valores reais de parâmetro por forma de consulta, extraídos dos wrappers de prepared statement e reduzidos a linhas compactas — assim nada precisa varrer a tabela de workload em busca de valores. Ligado ao seu template pelo `body_hash`, um hash do corpo inteiro do statement | 1 h | 180 dias |

Mais o `collection_run`, trilha de auditoria de cada execução dos coletores. Essa importa mais do que parece: sem ela, um buraco nos dados é indistinguível de um coletor que morreu em silêncio.

**Qual tabela usar para quê:**

- `query_stat_delta` + `query_text` → *o que importa, quanto custa, e a forma da consulta.* O peso vem de `delta_executions`; a forma vem do `query_text`, que guarda o statement parametrizado completo com o prefixo de declaração de parâmetros, por exemplo `(@P1 varchar(16))SELECT ...`. Filtre `counter_reset = 0` ao somar — as notas de desenho explicam por quê.
- `xe_workload` → *o statement como foi executado, com os valores reais de parâmetro.* É a única fonte de valores de verdade, e o único lugar onde se vê o que o cliente enviou em vez do que o engine cacheou.

- `param_sample` → *valores reais de parâmetro, uníveis a um peso.* Junte com `query_text` pelo `body_hash`, e de lá com `query_stat_delta` pelo `query_hash`. **Filtre `body_hash IS NOT NULL`** em qualquer coisa que confie na atribuição: linhas coletadas antes dessa coluna existir foram casadas por prefixo de texto, e numa carga gerada por ORM o casamento por prefixo não é apenas incompleto — ele liga valores ao statement errado. Veja a [migração](migrations/2026-09-22-match-by-body-hash.sql).

O `xe_workload` em si não tem `query_hash`, então não pode ser unido aos pesos diretamente; isso é consequência deliberada da divisão de granularidade descrita abaixo, não descuido. O `param_sample` existe justamente para fazer essa ponte.

**E elas enxergam coisas diferentes.** O `query_stat_delta` registra statements *dentro* de procedures e funções; o `xe_workload` registra apenas a *chamada externa*. Uma procedure invocada por um job aparece na primeira como uma linha por statement interno, e na segunda como um único batch cujo texto é só o `EXEC`. Procurar no `xe_workload` o SQL interno de uma procedure devolve nada, e isso é comportamento correto.

## O que é criado

A pegada completa na instância, para você saber com o que está concordando antes de rodar o `deploy.sql`:

- **Um banco** (`dba_telemetry` por padrão), `RECOVERY SIMPLE`, com 12 tabelas e 3 views. Nada é criado no `master`, no `msdb` ou nos seus bancos de aplicação.
- **Uma event session de escopo de servidor**, `Workload_Capture`, criada parada.
- **8 stored procedures e 1 função inline** (`fn_body_hash`, a definição única da chave que liga amostra a template), todas no banco de telemetria:

| Procedure | O que faz |
|---|---|
| `usp_collect_query_stats` | Fotografa o `sys.dm_exec_query_stats` e calcula o delta contra a foto anterior, sinalizando reset de contador para que eviction do plan cache nunca produza valor negativo |
| `usp_shred_xe_workload` | Lê o conjunto `.xel` para frente a partir de um offset salvo, faz o shred do XML, decodifica o GUID do job do `client_app_name` do Agent, e relê do início se o offset ficou inválido |
| `usp_collect_job_runs` | Copia novas linhas do `sysjobhistory`, convertendo a duração em HHMMSS e normalizando timestamps para UTC |
| `usp_stamp_job_work` | Materializa o `did_work` nas linhas de job enquanto os eventos de origem ainda existem |
| `usp_collect_who_is_active` | Roda o `sp_WhoIsActive` numa tabela e remove as sessões que estão vivas mas sem trabalho |
| `usp_refresh_job_inventory` | Reconstrói o mapa de quais job steps tocam um determinado banco |
| `usp_collect_param_samples` | Amostra valores reais de parâmetro dos wrappers de prepared statement, reduzindo milhões de linhas com LOB a alguns milhares compactas |
| `usp_purge_telemetry` | Deletes de retenção em lote |

- **6 jobs do Agent**, com o dono configurado:

| Job | Intervalo | Por que esse intervalo |
|---|---|---|
| `… - WhoIsActive` | 1 min | O menor que uma schedule do Agent permite. Um amostrador não consegue medir query curta de forma alguma — está aqui para pegar o que *dura* |
| `… - Job Runs` | 2 min | O `sysjobhistory` guarda só ~200 linhas **por job**, então um job frequente pode reter apenas minutos de histórico. Um coletor lento perde execuções em silêncio |
| `… - Query Stats` | 5 min | O engine agrega esses contadores sozinho, então nada é perdido entre coletas |
| `… - XE Shred` | 5 min | O file target tem dias de buffer; não há pressa |
| `… - Param Samples` | 1 h | Cada execução acumula cobertura de formas mais raras, então de hora em hora converge em vez de exigir uma extração única grande |
| `… - Purge` | diário 04:00 | Retenção, mais o refresh do inventário de jobs |

Esses jobs deliberadamente **não têm guard de réplica**, ao contrário dos jobs de aplicação ao lado dos quais costumam ficar — veja [Em Availability Group](#em-availability-group).

## Retenção

Aplicada pela `usp_purge_telemetry`, que o job diário chama sem argumentos, então valem os defaults configurados. Deletes em lote de 50.000 linhas para que um acúmulo não vire uma transação longa.

| Tabela | Padrão | Coluna de corte | |
|---|---|---|---|
| `xe_workload` | 30 dias | `event_time_utc` | UTC |
| `who_is_active` | 30 dias | `collection_time` | **local do servidor** |
| `wia_collection` | acompanha o `who_is_active` | — | o mapa local→UTC; a linha vive enquanto uma amostra a referenciar |
| `query_stat_delta` | 90 dias | `collected_at` | UTC |
| `job_run` | 365 dias | `collected_at` | UTC |
| `param_sample` | 180 dias | `collected_at` | UTC |
| `collection_run` | 60 dias | `started_at` | UTC |
| `query_text`, `capture_residue_archive` | nunca | — | tabelas de dimensão e auditoria, crescimento desprezível |

Duas coisas que vale entender em vez de só aceitar:

**A divisão UTC/local não é desleixo.** O `sp_WhoIsActive` grava o `collection_time` em hora local do servidor e o Extended Events grava em UTC. O purge respeita a base de cada coluna. Misturar as duas é a forma mais comum de errar esse tipo de query — veja as notas de desenho.

**O `job_run` sobreviver 11 meses além do `xe_workload` só funciona porque o `did_work` é materializado** na linha antes de os eventos expirarem. Sem isso, toda execução mais antiga que a janela de workload reportaria `did_work = 0`, indistinguível de um no-op de verdade — exatamente o oposto do propósito da flag.

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
migrations/             atualizações para instalações feitas antes de uma correção
uninstall/99_teardown   remove tudo (com guarda de confirmação)
queries/consumption.sql 10 queries para ler os dados
docs/design-notes*.md   as armadilhas, e por que o desenho é o que é
```

## Licença

MIT. Veja [LICENSE](LICENSE).
