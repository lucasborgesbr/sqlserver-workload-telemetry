/* ============================================================================
   Migration — fix statement text capture.

   Applies to installations made before 2026-09-14. Not needed for a fresh
   install: install/01 and install/02 already contain the corrected schema and
   collector.

   WHAT WAS WRONG

   1. query_text held the wrong text for statements inside procedures.
      sys.dm_exec_sql_text(sql_handle) returns the entire batch, which for a
      statement inside a procedure is the whole object definition. The
      collector stored that verbatim, so query_text ended up holding the
      object's DDL rather than the query. Measured on a real instance: 19 of
      21 procedure entries contained CREATE/DROP PROCEDURE.

   2. query_text was truncated at 4,000 characters, because MIN() does not
      accept nvarchar(max) and the aggregate was worked around with
      MIN(LEFT(text, 4000)). Measured: 12.6% of templates hit the ceiling,
      concentrated in verbose ORM-generated queries.

   3. There was no way to recover from either. The collector only fetched text
      for hashes it had never seen, so a row captured badly stayed bad.

   HOW TO APPLY

       sqlcmd -S <server> -E -I -b -i deploy.sql          -- picks up the fixed collector
       sqlcmd -S <server> -E -I -b -v TelemetryDatabase="dba_telemetry" \
              -i migrations/2026-09-14-fix-statement-text-capture.sql

   Then let the collector run a few cycles. Rows are recaptured as their plans
   reappear in cache, so this converges over hours rather than instantly.
   Track progress with query 2b in queries/consumption.sql.

   Rows whose plan never returns to cache stay flagged with their old text.
   That is visible rather than silent, which is the point.
   ============================================================================ */
USE [$(TelemetryDatabase)];
GO

IF COL_LENGTH('dbo.query_text', 'needs_recapture') IS NULL
    ALTER TABLE dbo.query_text ADD needs_recapture bit NOT NULL
        CONSTRAINT df_query_text_needs_recapture DEFAULT (0);
GO
IF COL_LENGTH('dbo.query_text', 'captured_by') IS NULL
    ALTER TABLE dbo.query_text ADD captured_by varchar(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_query_text_recapture')
    CREATE NONCLUSTERED INDEX ix_query_text_recapture
        ON dbo.query_text (needs_recapture) WHERE needs_recapture = 1;
GO

/* Provenance: anything already present came from the old logic. */
UPDATE dbo.query_text
   SET captured_by = 'legacy-4000'
 WHERE captured_by IS NULL;
GO

/* Flag what is known to be wrong:
     object_name IS NOT NULL  -> statement inside an object; text is the DDL
     >= 4000 characters       -> truncated by the old LEFT()                 */
UPDATE dbo.query_text
   SET needs_recapture = 1
 WHERE captured_by = 'legacy-4000'
   AND (object_name IS NOT NULL
        OR DATALENGTH(query_text) / 2 >= 4000);
GO

SELECT ISNULL(db_name, '(null)')                                          AS db,
       COUNT(*)                                                          AS templates,
       SUM(CONVERT(int, needs_recapture))                                AS flagged,
       SUM(CASE WHEN object_name IS NOT NULL THEN 1 ELSE 0 END)          AS inside_objects,
       SUM(CASE WHEN DATALENGTH(query_text)/2 >= 4000 THEN 1 ELSE 0 END) AS truncated
FROM dbo.query_text
GROUP BY db_name
ORDER BY COUNT(*) DESC;
GO
PRINT 'Migration applied. Let the collector run; track with consumption query 2b.';
GO
