/* ============================================================================
   Consumption queries. Run these in the telemetry database.

   Time zone matters here and is easy to get wrong:
     event_time_utc, collected_at, run_started_utc  -> UTC     -> SYSUTCDATETIME()
     run_started_at, collection_time                -> LOCAL   -> GETDATE()
   who_is_active.collection_time is the one local column you are likely to hit
   by accident. Read the sampler through vw_who_is_active, which adds
   collection_time_utc, and everything is UTC again.

   Which table answers what:
     query_stat_delta + query_text  -> WHAT matters, WHAT IT COSTS, and the
                                       query's SHAPE — aggregated, weighted
     xe_workload                    -> the FULL statement as executed, WITH
                                       real parameter values, plus per-event
                                       duration and I/O
     param_sample                   -> parameter VALUES per shape, already
                                       reduced. Use this instead of scanning
                                       xe_workload for values.
     job_run / vw_job_run_effective -> job durations and did_work
     who_is_active / vw_who_is_active -> long-running and blocking. Prefer
                                       the view: it carries a UTC timestamp.
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

   NOTE the counter_reset = 0 predicate, and do not drop it. On a reset row
   the delta_* columns hold the CUMULATIVE value, not an interval delta — that
   is how the collector avoids emitting negatives when a plan is recompiled or
   evicted. Summing without the filter therefore double-counts. Measured on a
   real instance: 12% of rows were resets, inflating total executions by 4%
   overall and up to 15% on individual templates. Enough to distort a ranking,
   not enough to be obvious.
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
      AND d.counter_reset    = 0          -- see note above; do not remove
    GROUP BY d.query_hash
) x
LEFT JOIN dbo.query_text t ON t.query_hash = x.query_hash
ORDER BY x.executions DESC;


/* ---------------------------------------------------------------------------
   2b. Text capture health.

   needs_recapture = 1 means the stored text is known or suspected wrong and
   the collector will overwrite it the next time that plan is in cache. Rows
   that stay pending for a long time belong to queries whose plan rarely
   returns to cache; their text is the best available, not the correct one.
   --------------------------------------------------------------------------- */
SELECT ISNULL(captured_by, '(unknown)')                                  AS captured_by,
       COUNT(*)                                                          AS templates,
       SUM(CONVERT(int, needs_recapture))                                AS pending_recapture,
       SUM(CASE WHEN object_name IS NOT NULL THEN 1 ELSE 0 END)          AS inside_objects,
       MAX(DATALENGTH(query_text) / 2)                                    AS longest_chars
FROM dbo.query_text
GROUP BY captured_by
ORDER BY COUNT(*) DESC;


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
SELECT collection_time_utc, session_id, [database_name], login_name, [program_name],
       [dd hh:mm:ss.mss] AS elapsed, status, blocking_session_id, open_tran_count,
       LEFT(CONVERT(nvarchar(max), sql_text), 300) AS sql_snippet
FROM dbo.vw_who_is_active
WHERE collection_time_utc > DATEADD(day, -1, SYSUTCDATETIME())
  AND (blocking_session_id IS NOT NULL OR status <> 'sleeping')
ORDER BY collection_time_utc DESC;


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


/* ---------------------------------------------------------------------------
   11. Parameter value samples, ready to feed a replay harness.

   Joins the three things a replayable workload needs: weight from
   query_stat_delta, shape from query_text, values from param_sample.

   value_segment is the raw slice that CONTAINS the values, not one value per
   column — see install/07 for why that split is left to the consumer.

   body_hash IS NOT NULL is not optional. Rows without it were collected
   before the sampler keyed on the whole body, and were matched by text
   prefix; on an ORM workload that binds values to the WRONG statement rather
   than leaving them unmatched. Grouping by body_hash rather than by
   stmt_prefix matters for the same reason — the prefix is not an identifier.
   --------------------------------------------------------------------------- */
SELECT TOP 50
       w.executions,
       ps.param_decl,
       COUNT(*)                                    AS distinct_values_sampled,
       MIN(ps.body_len)                            AS body_len,
       MIN(ps.event_time_utc)                      AS first_seen,
       MAX(ps.event_time_utc)                      AS last_seen,
       CONVERT(nvarchar(160), MIN(ps.stmt_prefix)) AS body_prefix
FROM dbo.param_sample ps
JOIN (
    SELECT query_hash, SUM(delta_executions) AS executions
    FROM dbo.query_stat_delta
    WHERE collected_at  > DATEADD(day, -7, SYSUTCDATETIME())
      AND counter_reset = 0
    GROUP BY query_hash
) w ON w.query_hash = ps.query_hash
WHERE ps.body_hash IS NOT NULL
GROUP BY w.executions, ps.body_hash, ps.param_decl
ORDER BY w.executions DESC;


/* ---------------------------------------------------------------------------
   11c. Audit the attribution instead of trusting it.

   Every body should resolve to exactly one query_hash. Anything above 1 means
   two templates are colliding on the key, which on this design can only
   happen when query_text holds a TRUNCATED statement — a body captured at the
   old 4,000-character cap hashes as a prefix of the real one. The fix is to
   finish the text recapture, not to change the key.
   --------------------------------------------------------------------------- */
SELECT hashes_per_body,
       COUNT(*) AS bodies
FROM (
    SELECT body_hash, COUNT(DISTINCT query_hash) AS hashes_per_body
    FROM dbo.param_sample
    WHERE body_hash IS NOT NULL
      AND query_hash IS NOT NULL
    GROUP BY body_hash
) z
GROUP BY hashes_per_body
ORDER BY hashes_per_body;


/* ---------------------------------------------------------------------------
   11b. Sampler health and coverage.

   parse_status other than ok/ok_no_params means the wrapper did not match the
   expected shape. A rising count there means the client changed how it sends
   statements, and the parser needs revisiting.
   --------------------------------------------------------------------------- */
SELECT parse_status,
       COUNT(*)                                                   AS samples,
       COUNT(DISTINCT body_hash)                                  AS distinct_shapes,
       SUM(CASE WHEN query_hash IS NOT NULL THEN 1 ELSE 0 END)    AS matched_to_template,
       CAST(100.0 * SUM(CASE WHEN query_hash IS NOT NULL THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0) AS decimal(5,1))                AS pct_matched
FROM dbo.param_sample
GROUP BY parse_status
ORDER BY COUNT(*) DESC;
