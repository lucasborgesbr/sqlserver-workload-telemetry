/* ============================================================================
   01 - Telemetry database and schema.

   The telemetry database is deliberately kept OUT of any Availability Group.
   Monitoring data should not depend on the thing it monitors, and a database
   inside an AG is read-only on the secondary, which would stop a collector
   running there from writing anything. Deploy one copy per node; the
   node_name column identifies the origin.

   Idempotent: safe to re-run. Existing data is never touched.
   ============================================================================ */
IF DB_ID('$(TelemetryDatabase)') IS NULL
    CREATE DATABASE [$(TelemetryDatabase)];
GO
ALTER DATABASE [$(TelemetryDatabase)] SET RECOVERY SIMPLE;
GO
USE [$(TelemetryDatabase)];
GO

/* ---------------------------------------------------------------------------
   Audit trail of the collectors themselves. This is what lets you prove that
   collection had no gaps, which matters more than it sounds: without it, a
   quiet period in the data is indistinguishable from a collector that died.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.collection_run') IS NULL
CREATE TABLE dbo.collection_run (
    run_id        bigint IDENTITY(1,1) PRIMARY KEY,
    collector     sysname        NOT NULL,
    node_name     sysname        NOT NULL DEFAULT (CONVERT(sysname, SERVERPROPERTY('MachineName'))),
    started_at    datetime2(3)   NOT NULL DEFAULT (SYSUTCDATETIME()),
    ended_at      datetime2(3)   NULL,
    rows_written  bigint         NULL,
    status        varchar(20)    NOT NULL DEFAULT ('running'),
    error_message nvarchar(2000) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_collection_run_collector')
    CREATE NONCLUSTERED INDEX ix_collection_run_collector
        ON dbo.collection_run (collector, started_at DESC);
GO

/* ---------------------------------------------------------------------------
   Query text dimension. Keyed by query_hash so the text is stored once per
   query shape rather than repeated in every snapshot row.

   Deliberately truncated to 4000 characters: this exists to LABEL aggregated
   rows, not to be a source of full query text. Full text with real parameter
   values lives in xe_workload.statement_text.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.query_text') IS NULL
CREATE TABLE dbo.query_text (
    query_hash  binary(8)     NOT NULL PRIMARY KEY,
    query_text  nvarchar(max) NULL,
    db_name     sysname       NULL,
    object_name sysname       NULL,
    first_seen  datetime2(3)  NOT NULL DEFAULT (SYSUTCDATETIME()),
    last_seen   datetime2(3)  NOT NULL DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------------------------------------------------------------------------
   Per-interval deltas from sys.dm_exec_query_stats. This is the Query Store
   substitute for instances older than SQL Server 2016.

   Both the delta AND the cumulative value are stored. The cumulative one is
   what makes counter-reset detection possible: when a plan is recompiled or
   evicted from cache the engine's counters restart, and a naive subtraction
   produces a negative delta.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.query_stat_delta') IS NULL
CREATE TABLE dbo.query_stat_delta (
    delta_id              bigint IDENTITY(1,1) PRIMARY KEY,
    collected_at          datetime2(3)  NOT NULL,
    node_name             sysname       NOT NULL,
    dbid                  int           NULL,
    db_name               sysname       NULL,
    query_hash            binary(8)     NULL,
    query_plan_hash       binary(8)     NULL,
    plan_handle           varbinary(64) NULL,
    creation_time         datetime2(3)  NULL,
    cum_execution_count   bigint        NULL,
    cum_worker_time_us    bigint        NULL,
    delta_executions      bigint        NULL,
    delta_worker_time_us  bigint        NULL,
    delta_elapsed_time_us bigint        NULL,
    delta_logical_reads   bigint        NULL,
    delta_physical_reads  bigint        NULL,
    delta_writes          bigint        NULL,
    delta_rows            bigint        NULL,
    counter_reset         bit           NOT NULL DEFAULT (0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_qsd_collected')
    CREATE NONCLUSTERED INDEX ix_qsd_collected ON dbo.query_stat_delta (collected_at DESC)
        INCLUDE (dbid, delta_executions, delta_worker_time_us);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_qsd_hash')
    CREATE NONCLUSTERED INDEX ix_qsd_hash ON dbo.query_stat_delta (query_hash, collected_at DESC);
GO

/* Previous snapshot, used to compute the deltas above. Replaced wholesale on
   every collection. */
IF OBJECT_ID('dbo.query_stats_prev') IS NULL
CREATE TABLE dbo.query_stats_prev (
    plan_handle            varbinary(64) NOT NULL,
    statement_start_offset int           NOT NULL,
    creation_time          datetime2(3)  NULL,
    query_hash             binary(8)     NULL,
    dbid                   int           NULL,
    execution_count        bigint        NULL,
    total_worker_time      bigint        NULL,
    total_elapsed_time     bigint        NULL,
    total_logical_reads    bigint        NULL,
    total_physical_reads   bigint        NULL,
    total_writes           bigint        NULL,
    total_rows             bigint        NULL,
    CONSTRAINT pk_query_stats_prev PRIMARY KEY (plan_handle, statement_start_offset)
);
GO

/* ---------------------------------------------------------------------------
   Raw workload, shredded out of the Extended Events file target.

   statement_text is nvarchar(max) with no truncation: it carries the complete
   statement INCLUDING real parameter values. That makes this the source for
   replayable test cases, and also makes it production data — see the data
   sensitivity section of the README.

   Note that writes counts I/O PAGES, not rows. row_count counts rows. They
   answer different questions and neither alone is a reliable "did this do
   any work" signal; see docs/design-notes.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.xe_workload') IS NULL
CREATE TABLE dbo.xe_workload (
    event_id        bigint IDENTITY(1,1) PRIMARY KEY,
    node_name       sysname          NOT NULL,
    event_name      sysname          NOT NULL,
    event_time_utc  datetime2(3)     NOT NULL,
    event_sequence  bigint           NULL,
    database_id     int              NULL,
    db_name         sysname          NULL,
    object_name     nvarchar(256)    NULL,
    client_app_name nvarchar(256)    NULL,
    client_hostname nvarchar(128)    NULL,
    username        nvarchar(128)    NULL,
    session_id      int              NULL,
    duration_us     bigint           NULL,
    cpu_time_us     bigint           NULL,
    logical_reads   bigint           NULL,
    physical_reads  bigint           NULL,
    writes          bigint           NULL,
    row_count       bigint           NULL,
    result          varchar(20)      NULL,
    statement_text  nvarchar(max)    NULL,
    job_id          uniqueidentifier NULL,
    job_step_id     int              NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_xew_time')
    CREATE NONCLUSTERED INDEX ix_xew_time ON dbo.xe_workload (event_time_utc DESC)
        INCLUDE (database_id, duration_us, writes);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_xew_job')
    CREATE NONCLUSTERED INDEX ix_xew_job ON dbo.xe_workload (job_id, job_step_id, event_time_utc)
        INCLUDE (writes, cpu_time_us, row_count);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_xew_app')
    CREATE NONCLUSTERED INDEX ix_xew_app ON dbo.xe_workload (client_app_name, event_time_utc DESC);
GO
/* Supports the shredder's de-duplication predicate. Without it, shred time
   grows badly as the table fills. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_xew_dedupe')
    CREATE NONCLUSTERED INDEX ix_xew_dedupe
        ON dbo.xe_workload (node_name, event_sequence, event_time_utc);
GO

/* ---------------------------------------------------------------------------
   Shredder resume position, scoped by file path pattern. The scoping matters:
   with a single global bookmark, pointing the shredder at a different file set
   makes fn_xe_file_target_read_file fail with "the offset is invalid for log
   file", because the bookmarked file is not part of the requested set.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.xe_file_bookmark') IS NULL
CREATE TABLE dbo.xe_file_bookmark (
    file_name    nvarchar(400) NOT NULL PRIMARY KEY,   -- 400 chars: an
    last_offset  bigint        NOT NULL,               -- nvarchar(500) key
    path_pattern nvarchar(400) NULL,                   -- exceeds the 900-byte
    updated_at   datetime2(3)  NOT NULL                -- index key limit
                 DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------------------------------------------------------------------------
   Which Agent job steps touch a given database, either by running in its
   context or by naming it in the step command.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.job_step_inventory') IS NULL
CREATE TABLE dbo.job_step_inventory (
    job_id        uniqueidentifier NOT NULL,
    step_id       int              NOT NULL,
    touches_db    sysname          NOT NULL,   -- part of the key, so NOT NULL
    job_name      sysname          NOT NULL,
    step_name     sysname          NULL,
    subsystem     varchar(40)      NULL,
    step_database sysname          NULL,
    how           varchar(20)      NULL,       -- db_context | in_command
    job_enabled   bit              NULL,
    is_guard_step bit              NULL,
    refreshed_at  datetime2(3)     NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT pk_job_step_inventory PRIMARY KEY (job_id, step_id, touches_db)
);
GO

/* ---------------------------------------------------------------------------
   Job executions, copied incrementally out of msdb.dbo.sysjobhistory.

   run_started_at is server LOCAL time, as msdb reports it. run_started_utc is
   normalised at collection time and is the column the event correlation joins
   on, because Extended Events timestamps are UTC. Mixing the two silently
   matches nothing and raises no error.

   did_work and the work_* columns are materialized by usp_stamp_job_work
   while the source events still exist, so that job history outlives the
   workload retention window without losing the signal.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.job_run') IS NULL
CREATE TABLE dbo.job_run (
    job_run_id        bigint IDENTITY(1,1) PRIMARY KEY,
    node_name         sysname          NOT NULL,
    job_id            uniqueidentifier NOT NULL,
    job_name          sysname          NULL,
    step_id           int              NOT NULL,
    step_name         sysname          NULL,
    instance_id       int              NOT NULL,
    run_started_at    datetime2(3)     NULL,   -- server local
    run_started_utc   datetime2(3)     NULL,   -- normalised
    run_duration_sec  int              NULL,   -- real seconds, not HHMMSS
    run_status        int              NULL,
    run_status_desc   varchar(20)      NULL,
    is_secondary_noop bit              NOT NULL DEFAULT (0),
    message           nvarchar(1000)   NULL,
    did_work          bit              NULL,
    captured_events   int              NULL,
    work_writes       bigint           NULL,
    work_rows         bigint           NULL,
    work_cpu_ms       decimal(18,2)    NULL,
    work_stamped_at   datetime2(3)     NULL,
    collected_at      datetime2(3)     NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT uq_job_run UNIQUE (node_name, instance_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_job_run_job')
    CREATE NONCLUSTERED INDEX ix_job_run_job
        ON dbo.job_run (job_id, step_id, run_started_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_job_run_unstamped')
    CREATE NONCLUSTERED INDEX ix_job_run_unstamped
        ON dbo.job_run (work_stamped_at, run_started_utc)
        WHERE work_stamped_at IS NULL;
GO

/* ---------------------------------------------------------------------------
   Aggregate record of anything deleted from the capture tables outside the
   normal retention purge — for example data captured under an older session
   definition. Keeps the evidence behind such a decision auditable after the
   rows themselves are gone.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.capture_residue_archive') IS NULL
CREATE TABLE dbo.capture_residue_archive (
    archived_at      datetime2(3)  NOT NULL DEFAULT (SYSUTCDATETIME()),
    source_table     sysname       NOT NULL,
    bucket           nvarchar(200) NOT NULL,
    row_count        bigint        NULL,
    max_duration_sec decimal(12,1) NULL,
    sum_row_count    bigint        NULL,
    window_from      datetime2(3)  NULL,
    window_to        datetime2(3)  NULL,
    reason           nvarchar(400) NULL
);
GO
PRINT '01 - schema ready in [$(TelemetryDatabase)].';
GO
