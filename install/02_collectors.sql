/* ============================================================================
   02 - Collector procedures and the effective-job-run view.

   SQL Server 2014 has no CREATE OR ALTER, so every object is dropped and
   recreated. That is safe: no collected data lives in these objects.
   ============================================================================ */
USE [$(TelemetryDatabase)];
GO

/* ===========================================================================
   Query statistics delta collector — the Query Store substitute.
   =========================================================================== */
IF OBJECT_ID('dbo.usp_collect_query_stats') IS NOT NULL
    DROP PROCEDURE dbo.usp_collect_query_stats;
GO
CREATE PROCEDURE dbo.usp_collect_query_stats
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id bigint, @now datetime2(3) = SYSUTCDATETIME(),
            @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')), @rows bigint = 0;

    INSERT INTO dbo.collection_run (collector, node_name, started_at)
    VALUES ('query_stats', @node, @now);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        CREATE TABLE #cur (
            plan_handle varbinary(64), statement_start_offset int, statement_end_offset int,
            creation_time datetime2(3), query_hash binary(8), query_plan_hash binary(8),
            dbid int, sql_handle varbinary(64),
            execution_count bigint, total_worker_time bigint, total_elapsed_time bigint,
            total_logical_reads bigint, total_physical_reads bigint, total_writes bigint,
            total_rows bigint
        );

        /* Two traps in this SELECT. The DMV column is total_logical_writes,
           not total_writes. And statement_end_offset is required — without it
           the statement cannot be sliced out of the object definition further
           down, which was the original cause of proc text being captured as
           the object's DDL. */
        INSERT INTO #cur
        SELECT qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset,
               qs.creation_time, qs.query_hash, qs.query_plan_hash, da.dbid, qs.sql_handle,
               qs.execution_count, qs.total_worker_time, qs.total_elapsed_time,
               qs.total_logical_reads, qs.total_physical_reads, qs.total_logical_writes,
               qs.total_rows
        FROM sys.dm_exec_query_stats qs
        OUTER APPLY (SELECT CONVERT(int, value) AS dbid
                     FROM sys.dm_exec_plan_attributes(qs.plan_handle)
                     WHERE attribute = 'dbid') da;

        /* counter_reset covers three cases: a plan seen for the first time, a
           plan whose creation_time changed (recompiled), and a counter that
           went backwards (evicted and re-cached). Without it the subtraction
           produces negative deltas. */
        INSERT INTO dbo.query_stat_delta
              (collected_at, node_name, dbid, db_name, query_hash, query_plan_hash, plan_handle,
               creation_time, cum_execution_count, cum_worker_time_us,
               delta_executions, delta_worker_time_us, delta_elapsed_time_us,
               delta_logical_reads, delta_physical_reads, delta_writes, delta_rows, counter_reset)
        SELECT @now, @node, c.dbid, DB_NAME(c.dbid), c.query_hash, c.query_plan_hash, c.plan_handle,
               c.creation_time, c.execution_count, c.total_worker_time,
               CASE WHEN r.is_reset = 1 THEN c.execution_count      ELSE c.execution_count      - p.execution_count      END,
               CASE WHEN r.is_reset = 1 THEN c.total_worker_time    ELSE c.total_worker_time    - p.total_worker_time    END,
               CASE WHEN r.is_reset = 1 THEN c.total_elapsed_time   ELSE c.total_elapsed_time   - p.total_elapsed_time   END,
               CASE WHEN r.is_reset = 1 THEN c.total_logical_reads  ELSE c.total_logical_reads  - p.total_logical_reads  END,
               CASE WHEN r.is_reset = 1 THEN c.total_physical_reads ELSE c.total_physical_reads - p.total_physical_reads END,
               CASE WHEN r.is_reset = 1 THEN c.total_writes         ELSE c.total_writes         - p.total_writes         END,
               CASE WHEN r.is_reset = 1 THEN c.total_rows           ELSE c.total_rows           - p.total_rows           END,
               r.is_reset
        FROM #cur c
        LEFT JOIN dbo.query_stats_prev p
               ON p.plan_handle            = c.plan_handle
              AND p.statement_start_offset = c.statement_start_offset
        CROSS APPLY (SELECT CASE WHEN p.plan_handle IS NULL                  THEN 1
                                 WHEN p.creation_time <> c.creation_time     THEN 1
                                 WHEN c.execution_count < p.execution_count THEN 1
                                 ELSE 0 END AS is_reset) r
        WHERE (r.is_reset = 1 AND c.execution_count > 0)
           OR c.execution_count > p.execution_count;
        SET @rows = @@ROWCOUNT;

        /* --- statement text, one row per query_hash ------------------------
           sys.dm_exec_sql_text(sql_handle) returns the ENTIRE batch, and for a
           statement inside a procedure it returns the whole object definition.
           Storing that verbatim captures the object's DDL instead of the
           statement — measured on a real instance as 19 of 21 procedure
           entries containing CREATE/DROP PROCEDURE. The offset pair is what
           slices the actual statement out; statement_end_offset = -1 means
           "to the end of the batch".

           ROW_NUMBER rather than MIN() because MIN does not accept
           nvarchar(max). Working around that with MIN(LEFT(text, 4000)) was
           what silently truncated 12.6% of templates. */
        CREATE TABLE #txt (
            query_hash  binary(8) PRIMARY KEY,
            stmt_text   nvarchar(max),
            dbid        int,
            object_name sysname NULL
        );

        INSERT INTO #txt (query_hash, stmt_text, dbid, object_name)
        SELECT x.query_hash, x.stmt_text, x.dbid, x.object_name
        FROM (
            SELECT c.query_hash,
                   SUBSTRING(st.text,
                             (c.statement_start_offset / 2) + 1,
                             ((CASE c.statement_end_offset
                                    WHEN -1 THEN DATALENGTH(st.text)
                                    ELSE c.statement_end_offset
                               END - c.statement_start_offset) / 2) + 1) AS stmt_text,
                   c.dbid,
                   OBJECT_NAME(st.objectid, st.dbid)                     AS object_name,
                   ROW_NUMBER() OVER (PARTITION BY c.query_hash
                                      ORDER BY c.execution_count DESC)   AS rn
            FROM #cur c
            CROSS APPLY sys.dm_exec_sql_text(c.sql_handle) st
            WHERE c.query_hash IS NOT NULL
              AND st.text IS NOT NULL
        ) x
        WHERE x.rn = 1;

        /* New hashes only, so the plan cache is not re-read every collection. */
        INSERT INTO dbo.query_text
              (query_hash, query_text, db_name, object_name, needs_recapture, captured_by)
        SELECT t.query_hash, t.stmt_text, DB_NAME(t.dbid), t.object_name, 0, 'stmt-offset'
        FROM #txt t
        WHERE NOT EXISTS (SELECT 1 FROM dbo.query_text qt WHERE qt.query_hash = t.query_hash);

        /* Recapture: rows flagged as wrong or missing, whose plan is back in
           cache. This is what makes a bad capture recoverable at all. */
        UPDATE qt
           SET query_text      = t.stmt_text,
               object_name     = t.object_name,
               db_name         = ISNULL(DB_NAME(t.dbid), qt.db_name),
               needs_recapture = 0,
               captured_by     = 'stmt-offset',
               last_seen       = @now
        FROM dbo.query_text qt
        JOIN #txt t ON t.query_hash = qt.query_hash
        WHERE qt.needs_recapture = 1;

        UPDATE qt SET last_seen = @now
        FROM dbo.query_text qt
        WHERE EXISTS (SELECT 1 FROM #cur c WHERE c.query_hash = qt.query_hash);

        TRUNCATE TABLE dbo.query_stats_prev;
        INSERT INTO dbo.query_stats_prev
              (plan_handle, statement_start_offset, creation_time, query_hash, dbid,
               execution_count, total_worker_time, total_elapsed_time,
               total_logical_reads, total_physical_reads, total_writes, total_rows)
        SELECT plan_handle, statement_start_offset, creation_time, query_hash, dbid,
               execution_count, total_worker_time, total_elapsed_time,
               total_logical_reads, total_physical_reads, total_writes, total_rows
        FROM #cur;

        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), rows_written = @rows, status = 'ok'
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH
END
GO

/* ===========================================================================
   Extended Events shredder.

   Extended Events cannot write to a table, so the session writes to a
   rollover file set and this reads it forward from a stored offset.
   =========================================================================== */
IF OBJECT_ID('dbo.usp_shred_xe_workload') IS NOT NULL
    DROP PROCEDURE dbo.usp_shred_xe_workload;
GO
CREATE PROCEDURE dbo.usp_shred_xe_workload
    @path nvarchar(400) = N'$(XelDirectory)\$(XelBaseName)*.xel'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id bigint, @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')),
            @rows bigint = 0, @file nvarchar(400), @offset bigint, @fallback bit = 0;

    INSERT INTO dbo.collection_run (collector, node_name) VALUES ('xe_shred', @node);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT TOP 1 @file = file_name, @offset = last_offset
        FROM dbo.xe_file_bookmark
        WHERE path_pattern = @path
        ORDER BY updated_at DESC;

        CREATE TABLE #raw (file_name nvarchar(400), file_offset bigint, x xml);

        BEGIN TRY
            INSERT INTO #raw (file_name, file_offset, x)
            SELECT f.file_name, f.file_offset, CONVERT(xml, f.event_data)
            FROM sys.fn_xe_file_target_read_file(@path, NULL, @file, @offset) f;
        END TRY
        BEGIN CATCH
            /* Error 25722: the bookmarked offset is no longer valid, normally
               because rollover deleted that file. Without this fallback the
               shredder would stay broken forever. The NOT EXISTS predicate
               below keeps the re-read from double-inserting. */
            DELETE FROM #raw;
            INSERT INTO #raw (file_name, file_offset, x)
            SELECT f.file_name, f.file_offset, CONVERT(xml, f.event_data)
            FROM sys.fn_xe_file_target_read_file(@path, NULL, NULL, NULL) f;
            SET @fallback = 1;
        END CATCH

        INSERT INTO dbo.xe_workload
              (node_name, event_name, event_time_utc, event_sequence, database_id, db_name,
               object_name, client_app_name, client_hostname, username, session_id,
               duration_us, cpu_time_us, logical_reads, physical_reads, writes, row_count,
               result, statement_text, job_id, job_step_id)
        SELECT @node, s.event_name, s.event_time_utc, s.event_sequence, s.database_id,
               DB_NAME(s.database_id), s.object_name, s.app, s.host, s.usr, s.session_id,
               s.duration_us, s.cpu_time_us, s.logical_reads, s.physical_reads, s.writes,
               s.row_count, s.result, s.statement_text,
               /* The Agent puts the job GUID and step number in client_app_name,
                  which makes it a direct join key to msdb.dbo.sysjobs. */
               CASE WHEN s.app LIKE 'SQLAgent - TSQL JobStep (Job 0x%'
                    THEN TRY_CONVERT(uniqueidentifier, CONVERT(varbinary(16),
                             SUBSTRING(s.app, CHARINDEX('(Job 0x', s.app) + 5, 34), 1))
               END,
               CASE WHEN s.app LIKE '%: Step %'
                    THEN TRY_CONVERT(int, REPLACE(SUBSTRING(s.app, CHARINDEX(': Step ', s.app) + 7, 10), ')', ''))
               END
        FROM (SELECT x.value('(event/@name)[1]', 'sysname')                                       AS event_name,
                     x.value('(event/@timestamp)[1]', 'datetime2(3)')                             AS event_time_utc,
                     x.value('(event/action[@name="event_sequence"]/value)[1]', 'bigint')         AS event_sequence,
                     x.value('(event/action[@name="database_id"]/value)[1]', 'int')               AS database_id,
                     x.value('(event/data[@name="object_name"]/value)[1]', 'nvarchar(256)')       AS object_name,
                     x.value('(event/action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS app,
                     x.value('(event/action[@name="client_hostname"]/value)[1]', 'nvarchar(128)') AS host,
                     x.value('(event/action[@name="username"]/value)[1]', 'nvarchar(128)')        AS usr,
                     x.value('(event/action[@name="session_id"]/value)[1]', 'int')                AS session_id,
                     x.value('(event/data[@name="duration"]/value)[1]', 'bigint')                 AS duration_us,
                     x.value('(event/data[@name="cpu_time"]/value)[1]', 'bigint')                 AS cpu_time_us,
                     x.value('(event/data[@name="logical_reads"]/value)[1]', 'bigint')            AS logical_reads,
                     x.value('(event/data[@name="physical_reads"]/value)[1]', 'bigint')           AS physical_reads,
                     x.value('(event/data[@name="writes"]/value)[1]', 'bigint')                   AS writes,
                     x.value('(event/data[@name="row_count"]/value)[1]', 'bigint')                AS row_count,
                     x.value('(event/data[@name="result"]/text)[1]', 'varchar(20)')               AS result,
                     COALESCE(x.value('(event/data[@name="statement"]/value)[1]', 'nvarchar(max)'),
                              x.value('(event/data[@name="batch_text"]/value)[1]', 'nvarchar(max)')) AS statement_text
              FROM #raw) s
        WHERE NOT EXISTS (SELECT 1 FROM dbo.xe_workload w
                           WHERE w.node_name      = @node
                             AND w.event_sequence = s.event_sequence
                             AND w.event_time_utc = s.event_time_utc);
        SET @rows = @@ROWCOUNT;

        WITH mx AS (SELECT TOP 1 file_name, MAX(file_offset) AS max_off
                    FROM #raw GROUP BY file_name ORDER BY file_name DESC)
        MERGE dbo.xe_file_bookmark AS t
        USING (SELECT file_name, max_off, @path AS path_pattern FROM mx) AS s
           ON t.file_name = s.file_name AND t.path_pattern = s.path_pattern
        WHEN MATCHED THEN UPDATE SET last_offset = s.max_off, updated_at = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (file_name, last_offset, path_pattern)
                                VALUES (s.file_name, s.max_off, s.path_pattern);

        UPDATE dbo.collection_run
           SET ended_at = SYSUTCDATETIME(), rows_written = @rows, status = 'ok',
               error_message = CASE WHEN @fallback = 1
                                    THEN N'fallback: bookmarked offset invalid, re-read from start' END
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH
END
GO

/* ===========================================================================
   Job step inventory.
   =========================================================================== */
IF OBJECT_ID('dbo.usp_refresh_job_inventory') IS NOT NULL
    DROP PROCEDURE dbo.usp_refresh_job_inventory;
GO
CREATE PROCEDURE dbo.usp_refresh_job_inventory
    @db            sysname        = N'$(TargetDatabase)',
    @guard_pattern nvarchar(200)  = N'$(GuardStepPattern)'
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.job_step_inventory WHERE touches_db = @db;

    INSERT INTO dbo.job_step_inventory
          (job_id, step_id, touches_db, job_name, step_name, subsystem,
           step_database, how, job_enabled, is_guard_step)
    SELECT j.job_id, s.step_id, @db, j.name, s.step_name, s.subsystem, s.database_name,
           CASE WHEN s.database_name = @db THEN 'db_context' ELSE 'in_command' END,
           j.enabled,
           CASE WHEN s.command LIKE @guard_pattern THEN 1 ELSE 0 END
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
    WHERE s.database_name = @db
       OR s.command LIKE '%' + @db + '%';
END
GO

/* ===========================================================================
   did_work materialization.

   Judged at the RUN level, aggregating every event attributed to that job
   step inside the run window. row_count OR writes, never one alone:

     row_count > 0, writes = 0  -> work whose pages were already cached
     row_count > 0, writes > 0  -> work with physical writes
     row_count = 0, writes > 0  -> 'exec proc' batches, where the outer
                                   row_count reflects only the last statement
     both zero                  -> a genuine no-op
   =========================================================================== */
IF OBJECT_ID('dbo.usp_stamp_job_work') IS NOT NULL
    DROP PROCEDURE dbo.usp_stamp_job_work;
GO
CREATE PROCEDURE dbo.usp_stamp_job_work
    @settle_minutes int = 15,   -- margin for the shredder to have caught up
    @max_rows       int = 20000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id bigint, @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')),
            @rows bigint = 0;

    INSERT INTO dbo.collection_run (collector, node_name) VALUES ('stamp_did_work', @node);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        ;WITH target AS (
            SELECT TOP (@max_rows) r.*
            FROM dbo.job_run r
            WHERE r.work_stamped_at IS NULL
              AND r.step_id > 0
              AND r.run_started_utc < DATEADD(minute, -@settle_minutes, SYSUTCDATETIME())
            ORDER BY r.run_started_utc
        )
        UPDATE a
           SET captured_events = ISNULL(w.events, 0),
               work_writes     = ISNULL(w.total_writes, 0),
               work_rows       = ISNULL(w.total_rows, 0),
               work_cpu_ms     = w.total_cpu_ms,
               did_work        = CASE WHEN ISNULL(w.total_rows, 0)   > 0
                                        OR ISNULL(w.total_writes, 0) > 0
                                      THEN 1 ELSE 0 END,
               work_stamped_at = SYSUTCDATETIME()
        FROM target a
        OUTER APPLY (
            SELECT COUNT(*)                    AS events,
                   SUM(x.writes)               AS total_writes,
                   SUM(x.row_count)            AS total_rows,
                   SUM(x.cpu_time_us) / 1000.0 AS total_cpu_ms
            FROM dbo.xe_workload x
            WHERE x.job_id         = a.job_id
              AND x.job_step_id    = a.step_id
              AND x.event_time_utc >= a.run_started_utc
              AND x.event_time_utc <  DATEADD(second, ISNULL(a.run_duration_sec, 0) + 2,
                                              a.run_started_utc)
        ) w;
        SET @rows = @@ROWCOUNT;

        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), rows_written = @rows, status = 'ok'
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH
END
GO

/* ===========================================================================
   Job run collector.
   =========================================================================== */
IF OBJECT_ID('dbo.usp_collect_job_runs') IS NOT NULL
    DROP PROCEDURE dbo.usp_collect_job_runs;
GO
CREATE PROCEDURE dbo.usp_collect_job_runs
    @guard_pattern nvarchar(200) = N'$(GuardStepPattern)'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id bigint, @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')),
            @rows bigint = 0, @max_instance int, @utc_offset_min int;

    INSERT INTO dbo.collection_run (collector, node_name) VALUES ('job_runs', @node);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @max_instance = ISNULL(MAX(instance_id), 0) FROM dbo.job_run WHERE node_name = @node;

        /* SQL Server 2014 has no AT TIME ZONE, so the offset is captured now
           and applied to the local timestamps msdb reports. Historical DST
           boundaries are therefore approximate to within an hour. */
        SET @utc_offset_min = DATEDIFF(minute, GETDATE(), GETUTCDATE());

        INSERT INTO dbo.job_run (node_name, job_id, job_name, step_id, step_name, instance_id,
               run_started_at, run_started_utc, run_duration_sec, run_status, run_status_desc,
               is_secondary_noop, message)
        SELECT @node, h.job_id, j.name, h.step_id, h.step_name, h.instance_id,
               msdb.dbo.agent_datetime(h.run_date, h.run_time),
               DATEADD(minute, @utc_offset_min, msdb.dbo.agent_datetime(h.run_date, h.run_time)),
               /* run_duration is an int formatted HHMMSS, NOT seconds:
                  123 means 1 minute 23 seconds. */
               (h.run_duration / 10000) * 3600
                 + ((h.run_duration / 100) % 100) * 60
                 + (h.run_duration % 100),
               h.run_status,
               CASE h.run_status WHEN 0 THEN 'Failed'     WHEN 1 THEN 'Succeeded'
                                 WHEN 2 THEN 'Retry'      WHEN 3 THEN 'Canceled'
                                 WHEN 4 THEN 'InProgress' END,
               /* A replica guard step aborts by design on a secondary, which
                  records the run as a failure. Flagged, not discarded, so the
                  guard can be shown to be working. */
               CASE WHEN h.message LIKE @guard_pattern THEN 1 ELSE 0 END,
               LEFT(h.message, 1000)
        FROM msdb.dbo.sysjobhistory h
        JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
        WHERE h.instance_id > @max_instance;
        SET @rows = @@ROWCOUNT;

        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), rows_written = @rows, status = 'ok'
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH

    /* Stamping depends on shredded events, but the settle window above
       guarantees the ordering, not the call site. Wrapped separately so a
       stamping failure cannot lose the primary job-run data. */
    BEGIN TRY
        EXEC dbo.usp_stamp_job_work;
    END TRY
    BEGIN CATCH
        DECLARE @ignored int = 0;   -- already recorded in collection_run
    END CATCH
END
GO

/* ===========================================================================
   Effective job runs.

   Reads the materialized values when present and only falls back to the live
   join for runs the stamping pass has not reached yet. That fallback is what
   keeps recent runs visible; the materialized path is what keeps history
   meaningful after the workload retention window closes.
   =========================================================================== */
IF OBJECT_ID('dbo.vw_job_run_effective') IS NOT NULL
    DROP VIEW dbo.vw_job_run_effective;
GO
CREATE VIEW dbo.vw_job_run_effective
AS
SELECT r.job_run_id, r.node_name, r.job_id, r.job_name, r.step_id, r.step_name,
       r.run_started_at, r.run_started_utc, r.run_duration_sec, r.run_status_desc,
       r.is_secondary_noop,
       ISNULL(g.is_guard_step, 0)                              AS is_guard_step,
       COALESCE(r.captured_events, ISNULL(w.events, 0))        AS captured_events,
       COALESCE(r.work_writes,     ISNULL(w.total_writes, 0))  AS total_writes,
       COALESCE(r.work_rows,       ISNULL(w.total_rows, 0))    AS total_rows,
       COALESCE(r.work_cpu_ms,     w.total_cpu_ms)             AS total_cpu_ms,
       COALESCE(r.did_work,
                CASE WHEN ISNULL(w.total_rows, 0)   > 0
                       OR ISNULL(w.total_writes, 0) > 0
                     THEN 1 ELSE 0 END)                        AS did_work,
       CASE WHEN r.work_stamped_at IS NULL THEN 'live' ELSE 'materialized' END AS value_source
FROM dbo.job_run r
OUTER APPLY (
    /* Guard detection reads msdb directly rather than the inventory table,
       because the inventory only holds steps that touch the target database
       and a guard step normally does not mention it. */
    SELECT CASE WHEN s.command LIKE N'$(GuardStepPattern)' THEN 1 ELSE 0 END AS is_guard_step
    FROM msdb.dbo.sysjobsteps s
    WHERE s.job_id = r.job_id AND s.step_id = r.step_id
) g
OUTER APPLY (
    SELECT COUNT(*)                    AS events,
           SUM(x.writes)               AS total_writes,
           SUM(x.row_count)            AS total_rows,
           SUM(x.cpu_time_us) / 1000.0 AS total_cpu_ms
    FROM dbo.xe_workload x
    WHERE r.work_stamped_at IS NULL      -- skip the scan when already stamped
      AND x.job_id         = r.job_id
      AND x.job_step_id    = r.step_id
      AND x.event_time_utc >= r.run_started_utc
      AND x.event_time_utc <  DATEADD(second, ISNULL(r.run_duration_sec, 0) + 2,
                                      r.run_started_utc)
) w
WHERE r.step_id > 0;
GO

/* ---------------------------------------------------------------------------
   A safe default for reading query_stat_delta.

   counter_reset = 1 means the delta_* columns hold the CUMULATIVE counter
   rather than an interval delta — that is how the collector avoids emitting a
   negative when a plan is recompiled or evicted. Nothing in the column names
   says so, so every new consumer sums the table and silently double-counts.
   Measured on the instance this was built against: 12% of rows were resets,
   inflating total executions by 4.1% overall and up to 15.4% on individual
   templates. Enough to reorder a ranking, not enough to look wrong.

   Anything that needs the raw behaviour still reads the base table.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.vw_query_stat_delta_clean') IS NOT NULL
    DROP VIEW dbo.vw_query_stat_delta_clean;
GO
CREATE VIEW dbo.vw_query_stat_delta_clean
AS
SELECT * FROM dbo.query_stat_delta WHERE counter_reset = 0;
GO
PRINT '02 - collectors and views ready.';
GO
