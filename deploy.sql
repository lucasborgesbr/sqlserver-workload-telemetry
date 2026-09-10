/* ---------------------------------------------------------------------------
   Full deployment, in order. Run from the repository root:

       sqlcmd -S <server> -E -I -b -i deploy.sql

   -I is required: several scripts use XML methods, which need
   QUOTED_IDENTIFIER ON. -b makes sqlcmd stop on the first error.

   :r paths resolve relative to sqlcmd's working directory, so the repository
   root is the only supported place to run this from.

   Every script is idempotent: re-running the deployment is safe and will
   recreate procedures and jobs in place without touching collected data.
   --------------------------------------------------------------------------- */
:on error exit
:r config.sql
:r install/01_database_and_schema.sql
:r install/02_collectors.sql
:r install/03_who_is_active.sql
:r install/04_xevent_session.sql
:r install/05_agent_jobs.sql
:r install/06_purge.sql
GO
PRINT '';
PRINT '--------------------------------------------------------------------';
PRINT 'Deployment complete.';
PRINT '';
PRINT 'The capture session was created but NOT started, so nothing is being';
PRINT 'written yet. Review the session definition, then start it with:';
PRINT '';
PRINT '    ALTER EVENT SESSION [Workload_Capture] ON SERVER STATE = START;';
PRINT '';
PRINT 'Then confirm collection health after a few minutes with the first';
PRINT 'query in queries/consumption.sql.';
PRINT '--------------------------------------------------------------------';
GO
