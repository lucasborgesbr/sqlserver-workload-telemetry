/* ============================================================================
   04 - The Workload_Capture Extended Events session.

   Created but NOT started. Review it, then start it explicitly:
       ALTER EVENT SESSION [Workload_Capture] ON SERVER STATE = START;

   On an Availability Group, run this on EVERY replica. Event sessions are
   server-scoped, not AG-scoped, so a session that exists only on the current
   primary stops collecting silently the moment a failover happens.
   ============================================================================ */
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Workload_Capture')
    DROP EVENT SESSION [Workload_Capture] ON SERVER;
GO
CREATE EVENT SESSION [Workload_Capture] ON SERVER
ADD EVENT sqlserver.rpc_completed (
    SET collect_statement = 1
    ACTION (sqlserver.session_id, sqlserver.database_id, sqlserver.client_app_name,
            sqlserver.client_hostname, sqlserver.username, package0.event_sequence)
    WHERE (sqlserver.database_id <> $(ExcludeDatabaseId))
),
ADD EVENT sqlserver.sql_batch_completed (
    ACTION (sqlserver.session_id, sqlserver.database_id, sqlserver.client_app_name,
            sqlserver.client_hostname, sqlserver.username, package0.event_sequence)
    WHERE (sqlserver.database_id <> $(ExcludeDatabaseId))
)
ADD TARGET package0.event_file (
    SET filename           = N'$(XelDirectory)\$(XelBaseName).xel',
        max_file_size      = $(XelMaxFileSizeMB),   -- MB per file
        max_rollover_files = $(XelMaxFiles)         -- hard cap on disk usage
)
WITH (
    MAX_MEMORY           = 64 MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    TRACK_CAUSALITY      = OFF,
    STARTUP_STATE        = ON        -- survives a service restart
);
GO

/* ============================================================================
   FILTERING DECISIONS — read before changing any of this.

   1. There is no positive database filter, and adding one is a mistake.

      In Extended Events, database_id is the SESSION CONTEXT, not the object
      being touched. A job step that runs with master as its context and
      reaches another database by three-part name reports database_id = 1.
      Filtering to a single application database therefore drops exactly the
      cross-database work you most want to see, with no error and no warning.

      This was learned the hard way: a pilot session filtered to one database
      and silently missed a job running every ten seconds against it, because
      the job's step context was master.

      Filter by database offline, in analysis, where it is reversible.

   2. One database IS excluded: msdb (database_id 4 by default).

      msdb traffic is overwhelmingly SQL Agent talking to itself — polling its
      own schedule tables with sub-millisecond, zero-write queries — plus the
      Agent writing job history, which the job_run collector already reads
      from the source with better fidelity.

      It also contains Database Mail's queue reader, a Service Broker WAITFOR
      that is parked for minutes at a time by design. A single such event will
      wreck any p99 or maximum-duration calculation that is not filtered by
      database.

      This exclusion loses no job data: Agent job steps execute in the STEP's
      database context, never in msdb.

      Note the exclusion applies to THIS SESSION ONLY. The query statistics
      collector reads an instance-wide DMV and is not filtered, so msdb rows
      still appear in query_stat_delta. That is deliberate — the data there is
      aggregated, cheap, and has no duration percentiles to distort. Filter it
      at read time when it gets in the way.

   3. Do NOT filter on writes = 0 to reduce volume.

      writes counts I/O PAGES, not rows, and depends on buffer pool state. A
      statement that modifies rows whose pages are already cached reports
      writes = 0. Measured on a real instance: tens of thousands of events
      with writes = 0 had touched hundreds of thousands of rows. Filtering on
      writes discards the majority of real work.

      Even the stricter "no writes AND no rows" variant is wrong: it drops
      queries that legitimately returned nothing, and drops the prepare and
      unprepare round trips that are evidence of client-side chattiness.

      Exclude by ORIGIN, never by EFFECT.

   4. EVENT_RETENTION_MODE must stay ALLOW_SINGLE_EVENT_LOSS.

      With NO_EVENT_LOSS, SQL Server blocks user sessions when the event
      buffer fills. That is the classic way to take down a production instance
      with "just a small trace".
   ============================================================================ */
PRINT '04 - Workload_Capture created (not started).';
GO
