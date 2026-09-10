/* ============================================================================
   Consumption queries. Run these in the telemetry database.

   Time zone matters here and is easy to get wrong:
     event_time_utc, collected_at, run_started_utc  -> UTC     -> SYSUTCDATETIME()
     run_started_at, collection_time                -> LOCAL   -> GETDATE()

   Which table answers what:
     query_stat_delta + query_text  -> WHAT matters and WHAT IT COSTS
                                       (execution counts, CPU) — aggregated
     xe_workload                    -> the FULL statement text WITH real
                                       parameter values, plus per-event
                                       duration and I/O
     job_run / vw_job_run_effective -> job durations and did_work
     who_is_active                  -> long-running and blocking
   ============================================================================ */

/* ---------------------------------------------------------------------------
   1. Collection health. Run this FIRST.
   If a collector is missing, erroring, or stale, every query below is
   misleading — a gap in the data looks exactly like a quiet period.
   --------------------------------------------------------------------------- */
SELECT collector,
       COUNT(*)                                            AS runs,
       SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END)   AS errors,
       MAX(started_at)                                     AS last_run_utc,
       DATEDIFF(minute, MAX(started_at), SYSUTCDATETIME()) AS minutes_since_last,
       SUM(rows_written)                                   AS rows_written,
       MAX(DATEDIFF(millisecond, started_at, ended_at))    AS worst_ms
FROM dbo.collection_run
WHERE started_at > DATEADD(hour, -24, SYSUTCDATETIME())
GROUP BY collector
ORDER BY collector;


/* ---------------------------------------------------------------------------
   2. Most frequently executed queries.
   Order by x.cpu_seconds DESC instead for the most expensive by CPU.
   Add  AND d.db_name <> 'msdb'  to drop Agent bookkeeping.
   --------------------------------------------------------------------------- */
SELECT TOP 25
       x.db_name, x.executions, x.cpu_seconds, x.avg_cpu_ms, x.logical_reads,
       CONVERT(nvarchar(300), t.query_text) AS query_snippet
FROM (
    SELECT d.query_hash,
           MIN(d.db_name)                                                 AS db_name,
           SUM(d.delta_executions)                                        AS executions,
           CAST(SUM(d.delta_worker_time_us) / 1000000.0 AS decimal(18,1)) AS cpu_seconds,
           CAST(SUM(d.delta_worker_time_us) * 1.0
                / NULLIF(SUM(d.delta_executions), 0) / 1000.0
                AS decimal(18,3))                                         AS avg_cpu_ms,
           SUM(d.delta_logical_reads)                                     AS logical_reads
    FROM dbo.query_stat_delta d
    WHERE d.collected_at     > DATEADD(day, -7, SYSUTCDATETIME())
      AND d.delta_executions > 0
    GROUP BY d.query_hash
) x
LEFT JOIN dbo.query_text t ON t.query_hash = x.query_hash
ORDER BY x.executions DESC;


/* ---------------------------------------------------------------------------
   3. Latency distribution per database.
   Percentiles per database rather than instance-wide, because one database's
   maintenance window would otherwise dominate everything.
   --------------------------------------------------------------------------- */
SELECT db_name, event_count, p50_ms, p95_ms, p99_ms, max_ms
FROM (
    SELECT DISTINCT
           db_name,
           COUNT(*) OVER (PARTITION BY db_name) AS event_count,
           CAST(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY duration_us / 1000.0)
                OVER (PARTITION BY db_name) AS decimal(12,3)) AS p50_ms,
           CAST(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_us / 1000.0)
                OVER (PARTITION BY db_name) AS decimal(12,3)) AS p95_ms,
           CAST(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration_us / 1000.0)
                OVER (PARTITION BY db_name) AS decimal(12,3)) AS p99_ms,
           CAST(MAX(duration_us / 1000.0)
                OVER (PARTITION BY db_name) AS decimal(12,3)) AS max_ms
    FROM dbo.xe_workload
    WHERE event_time_utc > DATEADD(hour, -24, SYSUTCDATETIME())
      AND duration_us IS NOT NULL
) p
ORDER BY event_count DESC;


/* ---------------------------------------------------------------------------
   4. Workload composition — who actually generates the load.
   Often the most surprising query in the set: application traffic is
   frequently a minority of what hits the instance.
   --------------------------------------------------------------------------- */
SELECT db_name, client_app_name,
       COUNT(*)                                                       AS events,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1)) AS pct,
       SUM(row_count)                                                 AS rows_touched,
       SUM(writes)                                                    AS io_page_writes,
       CAST(SUM(cpu_time_us) / 1000000.0 AS decimal(12,1))            AS cpu_seconds
FROM dbo.xe_workload
WHERE event_time_utc > DATEADD(hour, -24, SYSUTCDATETIME())
GROUP BY db_name, client_app_name
ORDER BY COUNT(*) DESC;


/* ---------------------------------------------------------------------------
   5. Which job runs actually did work.
   The answer to "the job reports success in 0 seconds — did it do anything?"

   Always filter is_guard_step = 0. A precondition guard step returns rows by
   design and would otherwise be counted as work.
   --------------------------------------------------------------------------- */
SELECT job_name, step_id, step_name,
       COUNT(*)                                              AS runs,
       SUM(CONVERT(int, did_work))                           AS runs_with_work,
       COUNT(*) - SUM(CONVERT(int, did_work))                AS no_op_runs,
       SUM(total_rows)                                       AS rows_touched,
       SUM(total_writes)                                     AS io_page_writes,
       CAST(AVG(CONVERT(decimal(18,2), run_duration_sec)) AS decimal(10,2)) AS avg_sec,
       MAX(run_duration_sec)                                 AS max_sec
FROM dbo.vw_job_run_effective
WHERE run_started_at    > DATEADD(day, -7, GETDATE())
  AND is_guard_step     = 0
  AND is_secondary_noop = 0
  AND captured_events   > 0
GROUP BY job_name, step_id, step_name
ORDER BY COUNT(*) DESC;


/* ---------------------------------------------------------------------------
   6. Slowest job runs.
   --------------------------------------------------------------------------- */
SELECT TOP 30
       job_name, step_id, run_started_at, run_duration_sec, run_status_desc,
       did_work, total_rows, total_writes, total_cpu_ms, value_source
FROM dbo.vw_job_run_effective
WHERE run_started_at > DATEADD(day, -7, GETDATE())
  AND is_guard_step  = 0
ORDER BY run_duration_sec DESC, total_cpu_ms DESC;


/* ---------------------------------------------------------------------------
   7. Heaviest individual statements — the benchmark candidates.

   Ordering by logical_reads finds I/O-heavy work; ordering by duration_us
   finds long-running work. They are usually different queries.

   Exclude your own interactive sessions, or you will find your diagnostic
   queries at the top of your own list.
   --------------------------------------------------------------------------- */
SELECT TOP 30
       event_time_utc, db_name, client_app_name, client_hostname,
       CAST(duration_us / 60000000.0 AS decimal(10,1)) AS duration_min,
       CAST(cpu_time_us / 1000.0 AS decimal(14,0))     AS cpu_ms,
       logical_reads, physical_reads, writes, row_count,
       CONVERT(nvarchar(400), statement_text)          AS statement_snippet
FROM dbo.xe_workload
WHERE event_time_utc  > DATEADD(day, -7, SYSUTCDATETIME())
  AND client_app_name NOT IN ('SQLCMD', 'Microsoft SQL Server Management Studio',
                              'Microsoft SQL Server Management Studio - Query')
ORDER BY logical_reads DESC;

/* Attribute an outlier to its job. The Agent embeds the job GUID in
   client_app_name, which the shredder decodes into job_id and job_step_id. */
SELECT TOP 20
       j.name AS job_name, w.job_step_id,
       CAST(MAX(w.duration_us) / 60000000.0 AS decimal(10,1)) AS worst_min,
       CAST(MAX(w.cpu_time_us) / 1000.0 AS decimal(14,0))     AS worst_cpu_ms,
       MAX(w.logical_reads)                                   AS worst_logical_reads,
       COUNT(*)                                               AS events
FROM dbo.xe_workload w
JOIN msdb.dbo.sysjobs j ON j.job_id = w.job_id
WHERE w.event_time_utc > DATEADD(day, -7, SYSUTCDATETIME())
GROUP BY j.name, w.job_step_id
ORDER BY MAX(w.duration_us) DESC;


/* ---------------------------------------------------------------------------
   8. Round-trip churn.

   A client that prepares and unprepares every statement pays two to three
   network round trips per logical operation. When per-query time is well
   under a millisecond, round-trip count — and where the client runs relative
   to the server — matters far more than query tuning or server sizing. This
   is the query that makes that visible.
   --------------------------------------------------------------------------- */
SELECT client_app_name, object_name,
       COUNT(*) AS calls,
       CAST(COUNT(*) * 1.0
            / NULLIF(DATEDIFF(second, MIN(event_time_utc), MAX(event_time_utc)), 0)
            AS decimal(10,2))                            AS calls_per_second,
       CAST(AVG(duration_us) / 1000.0 AS decimal(12,3))  AS avg_ms
FROM dbo.xe_workload
WHERE event_time_utc > DATEADD(hour, -1, SYSUTCDATETIME())
  AND object_name IN ('sp_prepare', 'sp_prepexec', 'sp_execute', 'sp_unprepare',
                      'sp_cursorprepexec', 'sp_reset_connection')
GROUP BY client_app_name, object_name
ORDER BY COUNT(*) DESC;


/* ---------------------------------------------------------------------------
   9. Long-running and blocking.
   --------------------------------------------------------------------------- */
SELECT collection_time, session_id, [database_name], login_name, [program_name],
       [dd hh:mm:ss.mss] AS elapsed, status, blocking_session_id, open_tran_count,
       LEFT(CONVERT(nvarchar(max), sql_text), 300) AS sql_snippet
FROM dbo.who_is_active
WHERE collection_time > DATEADD(day, -1, GETDATE())
  AND (blocking_session_id IS NOT NULL OR status <> 'sleeping')
ORDER BY collection_time DESC;


/* ---------------------------------------------------------------------------
   10. Storage growth. Pair with query 1 to derive the real event rate:
       xe_workload rows divided by the collection window.
   --------------------------------------------------------------------------- */
SELECT t.name AS table_name, p.rows AS row_count,
       CAST(SUM(a.total_pages) * 8 / 1024.0 AS decimal(12,1))              AS mb,
       CAST(SUM(a.total_pages) * 8.0 * 1024 / NULLIF(p.rows, 0) AS decimal(12,0)) AS bytes_per_row
FROM sys.tables t
JOIN sys.indexes i          ON i.object_id = t.object_id
JOIN sys.partitions p       ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE i.index_id IN (0, 1)
GROUP BY t.name, p.rows
ORDER BY SUM(a.total_pages) DESC;
