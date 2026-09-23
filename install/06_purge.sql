/* ============================================================================
   06 - Retention.

   Deletes run in batches so a large backlog does not create one long
   transaction and inflate the log.

   Note the asymmetry in the defaults: job_run keeps a year while xe_workload
   keeps a month. That only works because did_work is MATERIALIZED onto
   job_run before the events expire (see usp_stamp_job_work). Without that,
   every run older than the workload window would report did_work = 0 and be
   indistinguishable from a genuine no-op.
   ============================================================================ */
USE [$(TelemetryDatabase)];
GO
IF OBJECT_ID('dbo.usp_purge_telemetry') IS NOT NULL DROP PROCEDURE dbo.usp_purge_telemetry;
GO
CREATE PROCEDURE dbo.usp_purge_telemetry
    @keep_days_workload     int = $(KeepDaysWorkload),
    @keep_days_querystats   int = $(KeepDaysQueryStats),
    @keep_days_whoisactive  int = $(KeepDaysWhoIsActive),
    @keep_days_jobruns      int = $(KeepDaysJobRuns),
    @keep_days_paramsamples int = $(KeepDaysParamSamples),
    @keep_days_collections  int = 60,
    @batch_size             int = 50000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id bigint, @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')),
            @deleted bigint = 0, @n int = 1;

    INSERT INTO dbo.collection_run (collector, node_name) VALUES ('purge', @node);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        SET @n = 1;
        WHILE @n > 0
        BEGIN
            DELETE TOP (@batch_size) FROM dbo.xe_workload
             WHERE event_time_utc < DATEADD(day, -@keep_days_workload, SYSUTCDATETIME());
            SET @n = @@ROWCOUNT; SET @deleted += @n;
        END

        SET @n = 1;
        WHILE @n > 0
        BEGIN
            DELETE TOP (@batch_size) FROM dbo.query_stat_delta
             WHERE collected_at < DATEADD(day, -@keep_days_querystats, SYSUTCDATETIME());
            SET @n = @@ROWCOUNT; SET @deleted += @n;
        END

        /* who_is_active.collection_time is server LOCAL time, as
           sp_WhoIsActive records it — hence GETDATE() and not
           SYSUTCDATETIME() on this one. */
        IF OBJECT_ID('dbo.who_is_active') IS NOT NULL
        BEGIN
            SET @n = 1;
            WHILE @n > 0
            BEGIN
                DELETE TOP (@batch_size) FROM dbo.who_is_active
                 WHERE collection_time < DATEADD(day, -@keep_days_whoisactive, GETDATE());
                SET @n = @@ROWCOUNT; SET @deleted += @n;
            END
        END

        /* The local-to-UTC mapping follows the samples it describes. Keyed off
           the samples rather than off a date, so the two can never disagree:
           a mapping row survives exactly as long as a sample references it. */
        IF OBJECT_ID('dbo.wia_collection') IS NOT NULL
        BEGIN
            SET @n = 1;
            WHILE @n > 0
            BEGIN
                DELETE TOP (@batch_size) c
                FROM dbo.wia_collection c
                WHERE NOT EXISTS (SELECT 1 FROM dbo.who_is_active w
                                   WHERE w.collection_time = c.collection_time);
                SET @n = @@ROWCOUNT; SET @deleted += @n;
            END
        END

        SET @n = 1;
        WHILE @n > 0
        BEGIN
            DELETE TOP (@batch_size) FROM dbo.job_run
             WHERE collected_at < DATEADD(day, -@keep_days_jobruns, SYSUTCDATETIME());
            SET @n = @@ROWCOUNT; SET @deleted += @n;
        END

        /* Guarded on existence so the deploy order of install/06 and
           install/07 does not matter. */
        IF OBJECT_ID('dbo.param_sample') IS NOT NULL
        BEGIN
            SET @n = 1;
            WHILE @n > 0
            BEGIN
                DELETE TOP (@batch_size) FROM dbo.param_sample
                 WHERE collected_at < DATEADD(day, -@keep_days_paramsamples, SYSUTCDATETIME());
                SET @n = @@ROWCOUNT; SET @deleted += @n;
            END
        END

        DELETE FROM dbo.collection_run
         WHERE started_at < DATEADD(day, -@keep_days_collections, SYSUTCDATETIME())
           AND run_id <> @run_id;

        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), rows_written = @deleted, status = 'ok'
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH
END
GO
PRINT '06 - purge ready.';
GO
