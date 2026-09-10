/* ---------------------------------------------------------------------------
   Deployment configuration.

   Copy this file to config.sql, edit the values, and keep config.sql out of
   version control (.gitignore already excludes it).

   These are sqlcmd scripting variables, substituted as plain text before the
   batch reaches the server, so they work inside identifiers, string literals
   and predicates alike. Run everything through sqlcmd, or through SSMS with
   SQLCMD Mode enabled — plain SSMS will not expand them.
   --------------------------------------------------------------------------- */

-- Database that will hold the telemetry. Created by install/01.
:setvar TelemetryDatabase  "dba_telemetry"

-- Application database you mainly care about. Only used to seed the job
-- inventory. Capture itself is instance-wide by design; see docs/design-notes.
:setvar TargetDatabase     "YourAppDatabase"

-- Where the Extended Events rollover files are written. The directory must
-- already exist and be writable by the SQL Server service account.
:setvar XelDirectory       "D:\SQLData"
:setvar XelBaseName        "workload_capture"

-- Size cap for the file target: MB per file x number of files.
:setvar XelMaxFileSizeMB   "512"
:setvar XelMaxFiles        "20"

-- Database excluded from capture. 4 is msdb, which is almost entirely SQL
-- Agent bookkeeping plus parked Service Broker readers. See the design notes
-- for why this is the only exclusion, and why filtering TO one database is a
-- mistake that silently loses cross-database work.
:setvar ExcludeDatabaseId  "4"

-- Owner for the created Agent jobs. Prefer a service account over a personal
-- login so the jobs survive staff changes.
:setvar JobOwner           "sa"

-- Prefix for the created Agent job names.
:setvar JobPrefix          "DBA Telemetry"

-- LIKE pattern that identifies a "guard" job step: a precondition step that
-- aborts the job when it should not run on this node (a common Availability
-- Group pattern is a step that raises an error unless the local replica is
-- primary). Guard steps return rows, so without this they look like work.
-- Set it to something that never matches if your jobs have no guard steps.
:setvar GuardStepPattern   "%not the Primary Server%"

-- Retention in days, applied by install/06 and the purge job.
:setvar KeepDaysWorkload    "30"
:setvar KeepDaysQueryStats  "90"
:setvar KeepDaysWhoIsActive "30"
:setvar KeepDaysJobRuns     "365"
