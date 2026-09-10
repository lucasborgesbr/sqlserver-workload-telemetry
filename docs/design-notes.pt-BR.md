# Notas de desenho e armadilhas

*[English version](design-notes.md)*

Cada item aqui causou um bug real durante a construção, e a maioria falha **em silêncio** — sem erro, apenas dado errado. Estão registrados para que a próxima pessoa não precise redescobri-los.

## Extended Events não escreve em tabela

Não existe target de tabela. Os targets disponíveis são `event_file`, `ring_buffer`, `histogram`, `event_counter` e `pair_matching`. Então "XEvents numa tabela" sempre significa:

```
sessão -> event_file (.xel) -> um job lê com fn_xe_file_target_read_file
       -> faz o shred do XML -> INSERT na tabela, retomando de um offset salvo
```

A peça do meio é a que as pessoas subestimam. Precisa de bookmark, deduplicação, e um fallback para quando o bookmark ficar inválido.

## database_id é o contexto da sessão, não o objeto tocado

Este é o mal-entendido mais destrutivo disponível aqui.

Em Extended Events, o `sqlserver.database_id` reporta o contexto de banco da *sessão*, não o banco cujos objetos o statement lê. Um job step configurado para rodar em `master` que alcança outro banco por nome de três partes reporta `database_id = 1`.

Consequência: uma sessão filtrada para um banco de aplicação descarta, em silêncio, todo o trabalho cross-database dirigido a ele. No caso que originou esta ferramenta, uma sessão-piloto filtrada assim perdeu um job que rodava **a cada dez segundos** contra o banco alvo — cerca de 100 execuções em 17 minutos de captura, zero eventos registrados, nenhum erro.

Capture sem filtro positivo de banco e filtre offline, onde a decisão é reversível.

## writes conta páginas, não linhas

O `writes` no `rpc_completed` e no `sql_batch_completed` é contagem de **páginas** de I/O, e depende do estado do buffer pool e do timing do checkpoint. O `row_count` conta linhas.

Medido numa instância real: **17.099 eventos com `writes = 0` tocaram 389.583 linhas**, porque as páginas envolvidas já estavam em cache. Qualquer filtro ou heurística construída só sobre `writes` vai, portanto, descartar ou classificar errado a maior parte do trabalho real.

## did_work é heurística, e a definição importa

O objetivo é distinguir uma execução de job que processou algo de uma que terminou em 0 segundos porque a fila estava vazia. Não existe flag para isso — um job condicional cujo conjunto de trabalho está vazio simplesmente não faz nada e reporta sucesso.

O sinal usado é: `row_count > 0 OR writes > 0`, agregado sobre os eventos atribuídos àquele job step dentro da janela da execução.

| row_count | writes | Significado |
|---|---|---|
| > 0 | 0 | Trabalho cujas páginas já estavam em cache — o caso comum |
| > 0 | > 0 | Trabalho com escrita física |
| 0 | > 0 | Batches do tipo `exec some_proc`, onde o `row_count` externo reflete só o último statement |
| 0 | 0 | No-op de verdade |

As duas metades são necessárias. Uma primeira tentativa usou só `writes > 0` e classificou errado centenas de execuções que de fato tocaram linhas.

### Julgue no nível da execução, não do evento

**Uma única execução de job produz vários eventos de batch, não um.** Medido em seis eventos por execução num job step: o trabalho em si, mais batches de protocolo e de opções `SET` que carregam zero linhas.

Contar eventos com zero linhas no `xe_workload` e chamá-los de no-op produziu um confiante "33% das execuções não fizeram nada" que era simplesmente falso — no nível de execução, todas as execuções capturadas daquele job tinham trabalhado. Use a `vw_job_run_effective`, que agrega por execução.

## Guard steps parecem trabalho

Um padrão comum em Availability Group é um step 1 que aborta o job a menos que a réplica local seja a primária, tipicamente lançando erro. Duas consequências:

- Num secundário, **toda execução é registrada como falha**, e isso é comportamento correto, não incidente. Marcado como `is_secondary_noop`.
- O guard em si roda uma query que retorna linhas, então o `did_work` vê trabalho. Marcado como `is_guard_step`.

Filtre os dois em qualquer análise de job. O `GuardStepPattern` na configuração controla a detecção.

## UTC versus hora local

Timestamps de Extended Events são em **UTC**. O `msdb.dbo.agent_datetime()` devolve **hora local do servidor**.

Correlacionar os dois sem normalizar retorna **zero correspondências e nenhum erro** — o join simplesmente não acha nada, o que se lê como "esse job não fez trabalho" em vez de como bug. Esse custou tempo real para descobrir.

O `job_run.run_started_utc` é normalizado no momento da coleta e é a coluna na qual a correlação faz join. SQL Server 2014 não tem `AT TIME ZONE`, então o offset é capturado com `DATEDIFF(minute, GETDATE(), GETUTCDATE())` quando a linha é gravada; fronteiras históricas de horário de verão ficam, por consequência, aproximadas dentro de uma hora.

## sysjobhistory tem duas armadilhas

**O `run_duration` é um inteiro no formato HHMMSS, não segundos.** `123` significa 1 minuto e 23 segundos, não 123 segundos. Tratar como segundos subestima execuções curtas e superestima grosseiramente as longas.

**A retenção é de aproximadamente 200 linhas por job**, controlada por uma propriedade do Agent. Isso é generoso para um job noturno e quase inútil para um frequente: um job rodando a cada dez segundos mantém cerca de **onze minutos** de histórico. Qualquer análise de duração de job precisa de coleta própria, e o coletor tem que rodar com frequência suficiente para nunca cair fora dessa janela. Daí o intervalo de dois minutos — cinco ainda caberia, mas uma única coleta atrasada perderia execuções em silêncio.

## O bookmark do shredder fica inválido

O `fn_xe_file_target_read_file` recebe um nome de arquivo e um offset iniciais para retomar. Duas formas de isso quebrar:

1. **O rollover apaga o arquivo do bookmark.** O offset salvo não existe mais e a função lança o erro 25722. Sem tratamento, o shredder fica quebrado permanentemente, não temporariamente.
2. **O bookmark pertence a outro conjunto de arquivos.** Apontar o shredder para outro caminho enquanto um bookmark global guarda um arquivo fora daquele padrão produz o mesmo erro. Daí a coluna `path_pattern` na tabela de bookmark.

O shredder captura o erro, relê do início dos arquivos disponíveis, e conta com o predicado de deduplicação para não inserir em duplicidade. O fallback é registrado em `collection_run.error_message` enquanto o status permanece `ok`, para ficar visível sem parecer alarmante.

Esse predicado de deduplicação precisa de índice em `(node_name, event_sequence, event_time_utc)`. Sem ele, o tempo de shred degrada muito conforme a tabela cresce — medido saindo de 3 segundos para 46 segundos dentro de um único dia.

## Um amostrador não consegue contar queries

O `sp_WhoIsActive` amostra requisições *ativas naquele instante*. A probabilidade de capturar uma query qualquer é aproximadamente a duração dela dividida pelo intervalo de amostragem. Com p99 na casa de poucos milissegundos e intervalo de um minuto, isso fica na ordem de 0,01%.

Então um amostrador não responde "quais queries mais executam" nem "qual é a latência típica" — essas vêm do `query_stat_delta` e do `xe_workload`, respectivamente. O que ele captura é o que **dura**: janelas de manutenção, jobs de integração, cadeias de bloqueio, qualquer coisa patológica.

Espere também que ele seja dominado por sessões vivas mas sem trabalho — workers internos do engine, conexões ociosas de pool, e leitores de fila do Service Broker estacionados em `WAITFOR` por minutos, por desenho. O filtro é por **nome de programa**, não por banco, porque excluir um banco inteiro aqui esconderia um job de verdade travado nele.

## Cuidado com seu próprio efeito observador

Dois sabores, ambos reais:

**Os próprios coletores.** Medidos em 0,5% dos eventos capturados, portanto desprezível — mas vale confirmar em vez de presumir, com a query 4.

**Suas sessões interativas.** Queries de diagnóstico contra um `xe_workload` de milhões de linhas — cálculos de percentil especialmente — acabaram entre os consumidores mais pesados da instância: 20 minutos e 3,7 milhões de milissegundos de CPU numa única query. Exclua seu próprio cliente da análise de outlier, ou você vai se encontrar no topo da sua própria lista.

## Waits estacionados envenenam estatística de latência

Um leitor de fila do Service Broker, ou qualquer outra coisa parada em `WAITFOR`, reporta duração de minutos sem custo e sem trabalho. Um único evento desses destrói um p99 ou um máximo.

Essa é grande parte do motivo pelo qual o msdb é excluído, mas não é exclusivo do msdb — verifique em qualquer outlier se o `cpu_time_us` está perto de zero junto com um `duration_us` enorme antes de concluir que achou uma query lenta.

## Limites de sintaxe do SQL Server 2014

Encontrados ao escrever isto, todos aplicáveis ao 2014 e ao 2012:

- Não existe `CREATE OR ALTER` (2016 SP1+). Todo objeto é `DROP` e depois `CREATE`.
- Não existe `AT TIME ZONE` (2016+). Veja a seção de UTC acima.
- Não existe Query Store (2016+). É a razão inteira desta ferramenta existir.
- O `fn_xe_file_target_read_file` não tem coluna `timestamp_utc` (2017+). O timestamp tem que ser extraído do XML do evento.
- Qualquer query usando métodos de XML precisa de `QUOTED_IDENTIFIER ON` — `sqlcmd -I`, ou SSMS, que já liga por padrão.
- A coluna da DMV é `total_logical_writes`, não `total_writes`.
- `off` é palavra reservada e não pode ser alias de coluna.
- Métodos de XML não são permitidos em `GROUP BY`. Faça o shred numa tabela temporária primeiro, depois agregue.
- `MIN`/`MAX` não aceitam `nvarchar(max)`. Faça `CONVERT` para um tipo limitado antes.
- `bit` não pode ser somado. Use `SUM(CONVERT(int, flag))`.
