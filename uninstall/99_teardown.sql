/* ============================================================================
   99 - Teardown. Removes everything this repository installs.

   DESTRUCTIVE: drops the telemetry database and all collected data.

   Guarded on purpose. Run with the confirmation variable set:

       sqlcmd -S <server> -E -I -b -v Confirm="YES" -i uninstall/99_teardown.sql

   ...and remember to source your config first, or pass the same variables:

       sqlcmd -S <server> -E -I -b -v Confirm="YES" -i uninstall/99_teardown.sql \
              -v TelemetryDatabase="dba_telemetry" -v JobPrefix="DBA Telemetry" \
              -v XelDirectory="D:\SQLData" -v XelBaseName="workload_capture"

   The .xel files themselves are NOT removed: T-SQL cannot delete files
   without enabling xp_cmdshell, which this tool will not do. Delete them from
   the operating system after running this.
   ============================================================================ */
SET NOCOUNT ON;
GO
IF '$(Confirm)' <> 'YES'
BEGIN
    RAISERROR('Refusing to run: pass -v Confirm="YES" to confirm teardown.', 16, 1);
END
GO

/* --- 1. Stop and drop the capture session ------------------------------- */
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'Workload_Capture')
    ALTER EVENT SESSION [Workload_Capture] ON SERVER STATE = STOP;
GO
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Workload_Capture')
BEGIN
    DROP EVENT SESSION [Workload_Capture] ON SERVER;
    PRINT '  dropped event session Workload_Capture';
END
GO

/* --- 2. Delete the Agent jobs ------------------------------------------- */
DECLARE @job_name sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE '$(JobPrefix) - %';
OPEN c;
FETCH NEXT FROM c INTO @job_name;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;
    PRINT '  deleted job ' + @job_name;
    FETCH NEXT FROM c INTO @job_name;
END
CLOSE c; DEALLOCATE c;
GO

/* --- 3. Drop the telemetry database ------------------------------------- */
IF DB_ID('$(TelemetryDatabase)') IS NOT NULL
BEGIN
    ALTER DATABASE [$(TelemetryDatabase)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$(TelemetryDatabase)];
    PRINT '  dropped database $(TelemetryDatabase)';
END
GO

PRINT '';
PRINT 'Teardown complete.';
PRINT '';
PRINT 'STILL TO DO BY HAND: delete the trace files, which T-SQL cannot touch:';
PRINT '    $(XelDirectory)\$(XelBaseName)*.xel';
PRINT '';
PRINT 'sp_WhoIsActive in master was NOT removed: it is a third-party tool that';
PRINT 'was a prerequisite, not something this repository installed.';
GO
