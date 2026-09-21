/* ============================================================================
   07 - Parameter value sampler.

   WHAT THIS IS FOR

   Building a replayable workload needs three things per query template: the
   weight (query_stat_delta), the shape (query_text), and REAL PARAMETER
   VALUES. Only xe_workload has the values, buried inside the sp_prepexec
   wrapper that any prepared-statement client emits. Reading the whole table
   to get them is expensive and unnecessary — values are a SAMPLING problem,
   not a census.

   This reduces millions of LOB-bearing events to a few thousand compact rows:
   the parameter declaration, a prefix of the query body, and the segment that
   contains the values. It runs as a job and accumulates coverage of rarer
   shapes across runs.

   WHAT IT DELIBERATELY DOES NOT DO

   It does not split each individual value into its own column. Statement
   bodies and values can both contain escaped single quotes, and delimiting
   that in T-SQL with CHARINDEX silently produces garbage on the cases it
   cannot handle. So it keeps the segment containing the values and leaves the
   final split to the consumer, where a real parser is trivial. The expensive
   part — the volume reduction — is done here.

   WRAPPER SHAPE

     declare @p1 int
     set @p1=1
     exec sp_prepexec @p1 output,
       N'@P1 datetime2',                           <- declaration
       N'SELECT ... WHERE x > @P1 ORDER BY ...',    <- body
       '2026-09-10 08:51:41.9837400'                <- values
     select @p1                                     <- always last
   ============================================================================ */
USE [$(TelemetryDatabase)];
GO

IF OBJECT_ID('dbo.param_sample') IS NULL
CREATE TABLE dbo.param_sample (
    sample_id       bigint IDENTITY(1,1) PRIMARY KEY,
    collected_at    datetime2(3)   NOT NULL DEFAULT (SYSUTCDATETIME()),
    node_name       sysname        NOT NULL,
    db_name         sysname        NULL,
    client_app_name nvarchar(256)  NULL,
    query_hash      binary(8)      NULL,   -- matched to query_text where possible
    param_decl      nvarchar(2000) NULL,   -- '@P1 varchar(16),@P2 int'
    stmt_prefix     nvarchar(400)  NULL,   -- body, clipped at 400 or at the boundary
    value_segment   nvarchar(1000) NULL,   -- from the boundary forward: the values
    event_time_utc  datetime2(3)   NULL,
    duration_us     bigint         NULL,
    row_count       bigint         NULL,
    parse_status    varchar(20)    NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_param_sample_hash')
    CREATE NONCLUSTERED INDEX ix_param_sample_hash
        ON dbo.param_sample (query_hash, collected_at DESC);
GO
/* De-duplicate on a hash, not on (stmt_prefix, value_segment): those two
   total 2,800 bytes, over the 900-byte index key limit. The CAST to
   varbinary(32) is required — HASHBYTES is typed as varbinary(8000) even
   though it returns 32 bytes, and without the CAST the index still overflows. */
IF COL_LENGTH('dbo.param_sample', 'shape_value_hash') IS NULL
    ALTER TABLE dbo.param_sample ADD shape_value_hash AS
        CAST(HASHBYTES('SHA2_256', ISNULL(stmt_prefix, N'') + N'|'
                                 + ISNULL(value_segment, N'')) AS varbinary(32)) PERSISTED;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_param_sample_shape')
    CREATE NONCLUSTERED INDEX ix_param_sample_shape
        ON dbo.param_sample (shape_value_hash);
GO

IF OBJECT_ID('dbo.usp_collect_param_samples') IS NOT NULL
    DROP PROCEDURE dbo.usp_collect_param_samples;
GO
CREATE PROCEDURE dbo.usp_collect_param_samples
    @db                sysname       = N'$(TargetDatabase)',
    @app               nvarchar(256) = N'$(SampleClientApp)',
    @hours_back        int           = 6,
    @max_rows_read     int           = 20000,   -- caps LOB read cost
    @samples_per_shape int           = 25        -- distinct values kept per shape
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- it is a monitoring database

    DECLARE @run_id bigint, @node sysname = CONVERT(sysname, SERVERPROPERTY('MachineName')),
            @now datetime2(3) = SYSUTCDATETIME(), @rows bigint = 0;

    INSERT INTO dbo.collection_run (collector, node_name, started_at)
    VALUES ('param_samples', @node, @now);
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        /* --- 1. read a bounded sample and locate the anchors --------------
           Bounded by client_app_name + time window, which ix_xew_app covers.
           object_name is a residual predicate. The TOP is what controls the
           cost of reading LOB data. */
        SELECT
            r.event_id, r.event_time_utc, r.db_name, r.client_app_name,
            r.duration_us, r.row_count,
            a.anchor, h.has_decl, d1.decl_open, d2.decl_close, s1.stmt_open,
            e.tail_end, c.rel_close
        INTO #pos
        FROM (
            SELECT TOP (@max_rows_read)
                   w.event_id, w.event_time_utc, w.db_name, w.client_app_name,
                   w.duration_us, w.row_count,
                   CONVERT(nvarchar(max), w.statement_text) AS t
            FROM dbo.xe_workload w
            WHERE w.client_app_name = @app
              AND w.db_name         = @db
              AND w.object_name     = 'sp_prepexec'
              AND w.event_time_utc  > DATEADD(hour, -@hours_back, @now)
            ORDER BY w.event_id DESC
        ) r
        CROSS APPLY (SELECT CHARINDEX('exec sp_prepexec', r.t) AS anchor) a
        CROSS APPLY (SELECT CASE WHEN a.anchor > 0
                                 THEN CHARINDEX('N''', r.t, a.anchor) ELSE 0 END AS first_n) f
        /* When the statement takes no parameters, sp_prepexec is passed NULL
           in the declaration position, so the first N' found IS already the
           body. Without this check the whole body is extracted as if it were
           the declaration and overflows the column. A declaration always
           starts with @. */
        CROSS APPLY (SELECT CASE WHEN f.first_n > 0
                                  AND SUBSTRING(r.t, f.first_n + 2, 1) = N'@'
                                 THEN 1 ELSE 0 END AS has_decl) h
        CROSS APPLY (SELECT CASE WHEN h.has_decl = 1 THEN f.first_n ELSE 0 END AS decl_open) d1
        CROSS APPLY (SELECT CASE WHEN d1.decl_open > 0
                                 THEN CHARINDEX('''', r.t, d1.decl_open + 2) ELSE 0 END AS decl_close) d2
        CROSS APPLY (SELECT CASE WHEN h.has_decl = 1
                                 THEN CASE WHEN d2.decl_close > 0
                                           THEN CHARINDEX('N''', r.t, d2.decl_close) ELSE 0 END
                                 ELSE f.first_n END AS stmt_open) s1
        /* The wrapper always ends with 'select @p1'. The body also contains
           the word select, so the LAST occurrence is used, via REVERSE. */
        CROSS APPLY (SELECT CASE WHEN CHARINDEX(REVERSE('select @p1'), REVERSE(r.t)) > 0
                                 THEN DATALENGTH(r.t)/2
                                      - CHARINDEX(REVERSE('select @p1'), REVERSE(r.t))
                                      - 9
                                 ELSE DATALENGTH(r.t)/2 END AS tail_end) e
        /* --- the boundary between the SQL body and the value list ----------
           Everything below depends on knowing where the body literal closes.
           A fixed-width prefix cannot be used as a matching key: for a body
           shorter than the window, the window runs past the closing quote and
           swallows a parameter value, so the key changes on every execution
           and never matches query_text. Measured on this workload: every
           UPDATE and DELETE body is under 120 characters, which is the width
           the matching marker uses, so 100% of them failed to match.

           Finding the real closing quote means skipping doubled quotes.
           Replacing '' with two non-quote characters preserves every offset,
           so CHARINDEX on the masked copy returns a position valid in the
           original string. BIN2 is required: under some collations REPLACE
           does not preserve length, which would shift every offset. */
        CROSS APPLY (SELECT SUBSTRING(r.t, s1.stmt_open + 2, 4000) AS body_region) b
        CROSS APPLY (SELECT CHARINDEX(N'''',
                               REPLACE(b.body_region COLLATE Latin1_General_BIN2,
                                       N'''''', NCHAR(1) + NCHAR(1))) AS rel_close) c;

        SELECT p.event_id, p.event_time_utc, p.db_name, p.client_app_name,
               p.duration_us, p.row_count,
               CASE WHEN p.anchor    = 0 THEN 'no_anchor'
                    WHEN p.stmt_open = 0 THEN 'no_stmt'
                    WHEN p.has_decl  = 0 THEN 'ok_no_params'
                    WHEN p.decl_close = 0 THEN 'no_decl'
                    WHEN p.rel_close  = 0 THEN 'ok_no_bound'
                    ELSE 'ok' END AS parse_status,
               /* Defensive LEFT(): if the parse misjudges a boundary the row
                  is stored with a clipped declaration instead of failing the
                  whole collection. */
               CASE WHEN p.has_decl = 1 AND p.decl_close > p.decl_open + 2
                    THEN LEFT(SUBSTRING(w.st, p.decl_open + 2,
                                        p.decl_close - p.decl_open - 2), 2000)
               END AS param_decl,
               /* The body, clipped at 400 characters OR at the boundary,
                  whichever comes first. Clipping at the boundary is what makes
                  this a stable key for short statements. */
               CASE WHEN p.stmt_open > 0
                    THEN SUBSTRING(w.st, p.stmt_open + 2,
                                   CASE WHEN p.rel_close > 1 AND p.rel_close - 1 < 400
                                        THEN p.rel_close - 1 ELSE 400 END)
               END AS stmt_prefix,
               /* From the boundary forward, so the segment starts where the
                  values start instead of wherever a fixed window happened to
                  land. 1,000 characters covers 99.7% of value lists here
                  (measured: mean 20, max 2,560). */
               CASE WHEN p.rel_close > 0
                     AND p.tail_end > p.stmt_open + p.rel_close + 1
                    THEN SUBSTRING(w.st, p.stmt_open + p.rel_close + 2,
                                   CASE WHEN p.tail_end - (p.stmt_open + p.rel_close + 1) > 1000
                                        THEN 1000
                                        ELSE p.tail_end - (p.stmt_open + p.rel_close + 1) END)
                    /* Boundary not found: fall back to the trailing window, so
                       a parse miss degrades to noisy-but-present, not NULL. */
                    WHEN p.tail_end > 0
                    THEN SUBSTRING(w.st,
                                   CASE WHEN p.tail_end > 1000 THEN p.tail_end - 1000 ELSE 1 END,
                                   CASE WHEN p.tail_end > 1000 THEN 1000 ELSE p.tail_end END)
               END AS value_segment
        INTO #parsed
        FROM #pos p
        JOIN (SELECT event_id, CONVERT(nvarchar(max), statement_text) AS st
              FROM dbo.xe_workload
              WHERE event_id IN (SELECT event_id FROM #pos)) w
          ON w.event_id = p.event_id;

        /* --- 2. de-duplicate: N distinct values per shape ----------------- */
        SELECT * INTO #sampled
        FROM (
            SELECT x.*,
                   ROW_NUMBER() OVER (PARTITION BY x.stmt_prefix, x.value_segment
                                      ORDER BY x.event_id DESC) AS dup_rn,
                   DENSE_RANK()  OVER (PARTITION BY x.stmt_prefix
                                       ORDER BY x.value_segment)  AS val_rank
            FROM #parsed x
            WHERE x.parse_status LIKE 'ok%'
        ) y
        WHERE y.dup_rn = 1 AND y.val_rank <= @samples_per_shape;

        /* --- 3. match the shape to a query_hash --------------------------
           Done over DISTINCT shapes, not every sample, or the join against
           query_text becomes a cross product.
           Compares with LEFT() equality rather than LIKE, because query
           bodies contain underscore and bracket, which LIKE treats as
           wildcards. */
        SELECT DISTINCT s.param_decl, s.stmt_prefix
        INTO #shapes
        FROM #sampled s;

        /* Materialize the dimension once, and precompute where the statement
           actually begins. query_text stores some statements with a leading
           '(@P1 int,...)' declaration and some without, so the body does not
           start at a fixed position. The declaration's closing parenthesis is
           the first ')' followed by a letter: inner ones, from 'varchar(16)',
           are followed by ',' or ')'.

           body_head then gives pass 3b an equality predicate to join on, so
           the expensive full-prefix comparison only runs against real
           candidates. Without it, every unmatched shape scanned all of
           query_text and the run took 54s instead of 11s. */
        SELECT qt.query_hash, qt.last_seen, q.qtext, bs.body_start,
               CAST(SUBSTRING(q.qtext, bs.body_start, 60) AS nvarchar(60)) AS body_head
        INTO #qt
        FROM dbo.query_text qt
        CROSS APPLY (SELECT CONVERT(nvarchar(max), qt.query_text) AS qtext) q
        CROSS APPLY (SELECT CASE WHEN LEFT(q.qtext, 2) = N'(@'
                                  AND PATINDEX(N'%)[A-Za-z]%', q.qtext) > 0
                                 THEN PATINDEX(N'%)[A-Za-z]%', q.qtext) + 1
                                 ELSE 1 END AS body_start) bs
        WHERE qt.db_name = @db;

        CREATE NONCLUSTERED INDEX ix_qt_head ON #qt (body_head);

        SELECT sh.param_decl, sh.stmt_prefix, m.query_hash
        INTO #shape_hash
        FROM #shapes sh
        OUTER APPLY (
            SELECT TOP 1 qt.query_hash
            FROM #qt qt
            CROSS APPLY (SELECT N'(' + sh.param_decl + N')'
                              + LEFT(sh.stmt_prefix, 120) AS marker) mk
            WHERE LEFT(qt.qtext, DATALENGTH(mk.marker) / 2) = mk.marker
            /* A boundary-clipped prefix can be the entire statement, and a
               prefix match would then also accept any longer statement that
               starts the same way. Prefer the exact-length candidate. */
            ORDER BY CASE WHEN DATALENGTH(qt.qtext)
                               = DATALENGTH(mk.marker) THEN 0 ELSE 1 END,
                     qt.last_seen DESC
        ) m;

        /* --- 3b. second pass, declaration-independent --------------------
           The client declares each parameter with the width of the value it
           happens to be passing, so the SAME statement arrives as
           '@P1 varchar(16)' on one execution and '@P1 varchar(34)' on the
           next. Any key containing param_decl is therefore unstable by
           construction, and pass 3 misses every shape whose cached
           declaration was recorded at a different width. Measured here: it
           missed 7 of 11 UPDATE shapes and 3 of 6 DELETE shapes.

           So match on the body alone. The body must BEGIN the statement, which
           accepts both query_text spellings and rejects a body that merely
           occurs inside some larger statement.

           Only a UNIQUE candidate is accepted. A prefix of a verbose
           SQLAlchemy SELECT is mostly column list and can prefix up to 183
           different statements; binding one of those by a tie-break would
           put a plausible but wrong weight on the shape. An ambiguous shape
           is left NULL, which is honest and visible, and narrows as
           stmt_prefix widens. */
        UPDATE sh
           SET query_hash = m.query_hash
        FROM #shape_hash sh
        CROSS APPLY (
            SELECT CASE WHEN COUNT(DISTINCT qt.query_hash) = 1
                        THEN MIN(qt.query_hash) END AS query_hash
            FROM #qt qt
            WHERE qt.body_head = CAST(SUBSTRING(sh.stmt_prefix, 1, 60) AS nvarchar(60))
              AND CHARINDEX(sh.stmt_prefix, qt.qtext) = qt.body_start
        ) m
        WHERE sh.query_hash IS NULL;

        /* --- 4. store what is not already present ------------------------ */
        INSERT INTO dbo.param_sample
              (node_name, db_name, client_app_name, query_hash, param_decl,
               stmt_prefix, value_segment, event_time_utc, duration_us, row_count, parse_status)
        SELECT @node, s.db_name, s.client_app_name, sh.query_hash, s.param_decl,
               s.stmt_prefix, s.value_segment, s.event_time_utc, s.duration_us,
               s.row_count, s.parse_status
        FROM #sampled s
        LEFT JOIN #shape_hash sh
               ON sh.stmt_prefix = s.stmt_prefix
              AND ISNULL(sh.param_decl, N'') = ISNULL(s.param_decl, N'')
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.param_sample ps
             WHERE ps.shape_value_hash =
                   CAST(HASHBYTES('SHA2_256', ISNULL(s.stmt_prefix, N'') + N'|'
                                            + ISNULL(s.value_segment, N'')) AS varbinary(32)));
        SET @rows = @@ROWCOUNT;

        /* Parse diagnostics land in collection_run rather than in silence. */
        DECLARE @diag nvarchar(2000);
        SELECT @diag = N'read=' + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #parsed))
                     + N' ok='  + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #parsed WHERE parse_status LIKE 'ok%'))
                     + N' failed=' + ISNULL((SELECT STUFF((SELECT ', ' + parse_status + '=' + CONVERT(varchar(20), COUNT(*))
                                                           FROM #parsed WHERE parse_status NOT LIKE 'ok%'
                                                           GROUP BY parse_status
                                                           FOR XML PATH('')), 1, 2, '')), N'0');

        UPDATE dbo.collection_run
           SET ended_at = SYSUTCDATETIME(), rows_written = @rows, status = 'ok',
               error_message = @diag
         WHERE run_id = @run_id;
    END TRY
    BEGIN CATCH
        UPDATE dbo.collection_run SET ended_at = SYSUTCDATETIME(), status = 'error',
               error_message = LEFT(ERROR_MESSAGE(), 2000) WHERE run_id = @run_id;
        THROW;
    END CATCH
END
GO
PRINT '07 - parameter sampler ready.';
GO
