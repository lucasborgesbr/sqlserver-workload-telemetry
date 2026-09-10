/* ============================================================================
   05 - SQL Agent jobs that drive the collectors.

   Idempotent: an existing job with the same name is deleted and recreated.

   These jobs deliberately carry NO replica guard, unlike the application jobs
   this tool is often deployed alongside. Telemetry must collect on every
   node: the telemetry database is local to each one and node_name identifies
   the origin. A guard here would mean a secondary replica never collects
   anything at all.
   ============================================================================ */
USE msdb;
GO
SET NOCOUNT ON;

DECLARE @jobs TABLE (
    seq         int IDENTITY(1,1),
    job_name    sysname,
    step_name   sysname,
    command     nvarchar(1000),
    sched_name  sysname,
    subday_type int,          -- 1 = at a fixed time, 4 = every N minutes
    subday_int  int,
    start_time  int,
    rationale   nvarchar(400)
);

INSERT INTO @jobs (job_name, step_name, command, sched_name, subday_type, subday_int, start_time, rationale)
VALUES
 (N'$(JobPrefix) - Job Runs', N'Collect job runs',
  N'EXEC [$(TelemetryDatabase)].dbo.usp_collect_job_runs;',
  N'$(JobPrefix) JobRuns - 2 min', 4, 2, 0,
  N'sysjobhistory retains only ~200 rows PER JOB. A job running every 10s therefore keeps only minutes of history, so a slow collector loses runs silently.'),

 (N'$(JobPrefix) - WhoIsActive', N'Sample active requests',
  N'EXEC [$(TelemetryDatabase)].dbo.usp_collect_who_is_active;',
  N'$(JobPrefix) WIA - 1 min', 4, 1, 0,
  N'Smallest interval an Agent schedule allows. A sampler cannot measure short queries; it is here to catch what lasts.'),

 (N'$(JobPrefix) - Query Stats', N'Collect query stats delta',
  N'EXEC [$(TelemetryDatabase)].dbo.usp_collect_query_stats;',
  N'$(JobPrefix) QStats - 5 min', 4, 5, 0,
  N'The engine aggregates these counters itself, so nothing is lost between collections. Plan cache eviction is flagged by counter_reset.'),

 (N'$(JobPrefix) - XE Shred', N'Shred workload capture',
  N'EXEC [$(TelemetryDatabase)].dbo.usp_shred_xe_workload;',
  N'$(JobPrefix) Shred - 5 min', 4, 5, 0,
  N'The file target holds several days of buffer, so there is no urgency.'),

 (N'$(JobPrefix) - Purge', N'Purge and refresh inventory',
  N'EXEC [$(TelemetryDatabase)].dbo.usp_purge_telemetry; EXEC [$(TelemetryDatabase)].dbo.usp_refresh_job_inventory;',
  N'$(JobPrefix) Purge - daily', 1, 0, 40000,
  N'Retention plus a refresh of the job step inventory.');

DECLARE @seq int = 1, @max int, @job_name sysname, @step_name sysname, @command nvarchar(1000),
        @sched_name sysname, @subday_type int, @subday_int int, @start_time int,
        @rationale nvarchar(400), @owner sysname;

SELECT @max = MAX(seq) FROM @jobs;

/* Fall back to the deploying login if the configured owner does not exist or
   is disabled, rather than failing the whole deployment. */
SELECT @owner = CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals
                                   WHERE name = '$(JobOwner)' AND is_disabled = 0)
                     THEN '$(JobOwner)' ELSE SUSER_SNAME() END;

IF @owner <> '$(JobOwner)'
    PRINT 'WARNING: job owner "$(JobOwner)" not usable; jobs owned by ' + @owner + ' instead.';

WHILE @seq <= @max
BEGIN
    SELECT @job_name = job_name, @step_name = step_name, @command = command,
           @sched_name = sched_name, @subday_type = subday_type,
           @subday_int = subday_int, @start_time = start_time, @rationale = rationale
    FROM @jobs WHERE seq = @seq;

    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
        EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;

    EXEC msdb.dbo.sp_add_job
         @job_name         = @job_name,
         @enabled          = 1,
         @owner_login_name = @owner,
         @description      = @rationale,
         @category_name    = N'[Uncategorized (Local)]';

    EXEC msdb.dbo.sp_add_jobstep
         @job_name          = @job_name,
         @step_id           = 1,
         @step_name         = @step_name,
         @subsystem         = N'TSQL',
         @database_name     = N'$(TelemetryDatabase)',
         @command           = @command,
         @on_success_action = 1,
         @on_fail_action    = 2,
         @retry_attempts    = 1,
         @retry_interval    = 1;

    /* Schedule names must be unique across the instance, hence the prefix. */
    EXEC msdb.dbo.sp_add_schedule
         @schedule_name        = @sched_name,
         @enabled              = 1,
         @freq_type            = 4,              -- daily
         @freq_interval        = 1,
         @freq_subday_type     = @subday_type,
         @freq_subday_interval = @subday_int,
         @active_start_time    = @start_time;

    EXEC msdb.dbo.sp_attach_schedule @job_name = @job_name, @schedule_name = @sched_name;
    EXEC msdb.dbo.sp_add_jobserver   @job_name = @job_name, @server_name   = N'(local)';

    PRINT '  created: ' + @job_name;
    SET @seq += 1;
END
GO
PRINT '05 - Agent jobs ready.';
GO
