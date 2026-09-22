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
   the parameter declaration, a prefix of the query body for humans to read,
   the segment that contains the values, and a hash of the complete body that
   links the sample to its query_hash.

   WHAT IT DELIBERATELY DOES NOT DO

   It does not split each individual value into its own column. Statement
   bodies and values can both contain escaped single quotes, and delimiting
   that in T-SQL with CHARINDEX silently produces garbage on the cases it
   cannot handle. So it keeps the segment containing the values and leaves the
   final split to the consumer, where a real parser is trivial. The expensive
   part — the volume reduction — is done here.

   HOW THE SAMPLE IS LINKED TO A query_hash, AND WHY NOT BY PREFIX

   By a hash of the entire normalized statement body. A text PREFIX cannot do
   this job, however wide you make it. An ORM emits statements over the same
   table with the same expanded column list, diverging only at the JOIN, the
   WHERE or the ORDER BY. Measured on the instance this was built against:
   89% of bodies longer than 400 characters share their first 400 characters
   with another statement, the largest such group holding 192 distinct
   queries, and 71% of bodies longer than 4,000 characters still collide at
   4,000. Prefix matching on that workload does not merely fail to match — it
   matches the WRONG query and reports a plausible query_hash for values that
   belong to a different statement. Absence is detectable; a wrong answer that
   looks right is not.

   So stmt_prefix is kept for reading, and is not the key.

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
    query_hash      binary(8)      NULL,   -- matched via body_hash where possible
    body_hash       varbinary(32)  NULL,   -- THE key: hash of the whole body
    param_decl      nvarchar(2000) NULL,   -- '@P1 varchar(16),@P2 int'
    stmt_prefix     nvarchar(400)  NULL,   -- for reading only, NOT a key
    value_segment   nvarchar(1000) NULL,   -- from the boundary forward: the values
    body_len        int            NULL,   -- full body length, so truncation is visible
    event_time_utc  datetime2(3)   NULL,
    duration_us     bigint         NULL,
    row_count       bigint         NULL,
    parse_status    varchar(20)    NOT NULL
);
GO
/* Added after first release — guarded so re-deploy over an existing install
   works. Rows collected before this keep body_hash NULL and stay matched (or
   not) by the old prefix rule; see migrations/ for the backfill. */
IF COL_LENGTH('dbo.param_sample', 'body_hash') IS NULL
    ALTER TABLE dbo.param_sample ADD body_hash varbinary(32) NULL;
GO
IF COL_LENGTH('dbo.param_sample', 'body_len') IS NULL
    ALTER TABLE dbo.param_sample ADD body_len int NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_param_sample_hash')
    CREATE NONCLUSTERED INDEX ix_param_sample_hash
        ON dbo.param_sample (query_hash, collected_at DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_param_sample_body')
    CREATE NONCLUSTERED INDEX ix_param_sample_body
        ON dbo.param_sample (body_hash);
GO
/* The original de-duplication key was (stmt_prefix, value_segment), hashed
   because the two together exceed the 900-byte index key limit. It is kept so
   existing installs do not need the column dropped, but it is no longer what
   de-duplication uses: two different statements sharing a 400-character prefix
   would collapse into one, which is the same collision described above, and
   would silently discard samples of the rarer of the two. De-duplication now
   keys on (body_hash, value_segment).

   The CAST to varbinary(32) is required — HASHBYTES is typed as
   varbinary(8000) even though it returns 32 bytes, and without the CAST the
   index still overflows. */
IF COL_LENGTH('dbo.param_sample', 'shape_value_hash') IS NULL
    ALTER TABLE dbo.param_sample ADD shape_value_hash AS
        CAST(HASHBYTES('SHA2_256', ISNULL(stmt_prefix, N'') + N'|'
                                 + ISNULL(value_segment, N'')) AS varbinary(32)) PERSISTED;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_param_sample_shape')
    CREATE NONCLUSTERED INDEX ix_param_sample_shape
        ON dbo.param_sample (shape_value_hash);
GO
/* The same key on the dimension side, so a consumer can join the two directly
   and audit the attribution rather than trusting it. */
IF COL_LENGTH('dbo.query_text', 'body_hash') IS NULL
    ALTER TABLE dbo.query_text ADD body_hash varbinary(32) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_query_text_body')
    CREATE NONCLUSTERED INDEX ix_query_text_body
        ON dbo.query_text (body_hash);
GO

/* ---------------------------------------------------------------------------
   One definition of the key, used on both sides. It has to be one definition:
   the sample side and the dimension side must agree exactly or nothing
   matches, and two inlined copies of this expression would drift.

   An inline table-valued function, not a scalar one — the optimizer expands
   it, so there is no per-row scalar UDF penalty.

   Normalization collapses runs of whitespace to a single space and trims. The
   two sides should already be byte-identical, since both originate as the same
   client text, so this is insurance rather than a fix. It does not touch
   literals: the body arrives parameterized, so there are none to normalize.

   The '<>' trick usually used to collapse whitespace is unsafe here, because
   '<>' is a valid SQL operator and appears in real statement bodies. Control
   characters cannot.

   SQL Server 2014 rejects HASHBYTES input over 8,000 bytes, which is only
   4,000 nvarchar characters — well short of the 9,020-character bodies seen on
   this workload. So the body is hashed in three 4,000-character chunks and the
   chunk hashes are hashed together, covering 12,000 characters. SUBSTRING past
   the end returns an empty string rather than NULL, so short bodies still
   produce a deterministic value.
   --------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.fn_body_hash') IS NOT NULL DROP FUNCTION dbo.fn_body_hash;
GO
CREATE FUNCTION dbo.fn_body_hash (@body nvarchar(max))
RETURNS TABLE
AS RETURN
    SELECT CAST(HASHBYTES('SHA2_256',
                   CAST(HASHBYTES('SHA2_256', SUBSTRING(n.nb,     1, 4000)) AS varbinary(32))
                 + CAST(HASHBYTES('SHA2_256', SUBSTRING(n.nb,  4001, 4000)) AS varbinary(32))
                 + CAST(HASHBYTES('SHA2_256', SUBSTRING(n.nb,  8001, 4000)) AS varbinary(32))
               ) AS varbinary(32)) AS body_hash,
           LEN(n.nb) AS body_len
    FROM (
        SELECT LTRIM(RTRIM(
                 REPLACE(REPLACE(REPLACE(
                   REPLACE(REPLACE(REPLACE(@body, CHAR(13), N' '),
                                            CHAR(10), N' '),
                                            CHAR(9),  N' '),
                 N' ', NCHAR(1) + NCHAR(2)),
                 NCHAR(2) + NCHAR(1), N''),
                 NCHAR(1) + NCHAR(2), N' '))) AS nb
    ) n;
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
            @now datetime2(3) = SYSUTCDATETIME(), @rows bigint = 0, @dim_filled bigint = 0;

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
           Everything downstream depends on knowing where the body literal
           closes: it is the end of the key, and the start of the values.

           Finding the real closing quote means skipping doubled quotes.
           Replacing '' with two non-quote characters preserves every offset,
           so CHARINDEX on the masked copy returns a position valid in the
           original string. BIN2 is required: under some collations REPLACE
           does not preserve length, which would shift every offset.

           The search window is 12,000 characters because the longest body on
           this workload is 9,020. Scanning only 4,000 left every longer body
           with no detectable boundary. */
        CROSS APPLY (SELECT SUBSTRING(r.t, s1.stmt_open + 2, 12000) AS body_region) b
        CROSS APPLY (SELECT CHARINDEX(N'''',
                               REPLACE(b.body_region COLLATE Latin1_General_BIN2,
                                       N'''''', NCHAR(1) + NCHAR(1))) AS rel_close) c;

        /* --- 2. extract, and compute the key ----------------------------- */
        SELECT p.event_id, p.event_time_utc, p.db_name, p.client_app_name,
               p.duration_us, p.row_count,
               bh.body_hash, bh.body_len,
               CASE WHEN p.anchor     = 0 THEN 'no_anchor'
                    WHEN p.stmt_open  = 0 THEN 'no_stmt'
                    WHEN p.has_decl   = 0 THEN 'ok_no_params'
                    WHEN p.decl_close = 0 THEN 'no_decl'
                    WHEN p.rel_close  = 0 THEN 'ok_no_bound'
                    /* Flags that stmt_prefix holds only part of the body, so
                       nobody mistakes it for an identifier. The match is by
                       body_hash and is unaffected. */
                    WHEN bh.body_len  > 400 THEN 'ok_prefix_cut'
                    ELSE 'ok' END AS parse_status,
               /* Defensive LEFT(): if the parse misjudges a boundary the row
                  is stored with a clipped declaration instead of failing the
                  whole collection. */
               CASE WHEN p.has_decl = 1 AND p.decl_close > p.decl_open + 2
                    THEN LEFT(SUBSTRING(w.st, p.decl_open + 2,
                                        p.decl_close - p.decl_open - 2), 2000)
               END AS param_decl,
               /* For humans. Clipped at 400 or at the boundary, whichever is
                  first, so a short statement reads as its complete self. */
               CASE WHEN p.stmt_open > 0
                    THEN SUBSTRING(w.st, p.stmt_open + 2,
                                   CASE WHEN p.rel_close > 1 AND p.rel_close - 1 < 400
                                        THEN p.rel_close - 1 ELSE 400 END)
               END AS stmt_prefix,
               /* From the boundary forward, so the segment starts where the
                  values start instead of wherever a fixed window landed.
                  1,000 characters covers 99.7% of value lists here
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
          ON w.event_id = p.event_id
        /* The complete body, clipped at the boundary — this is what gets
           hashed, and it is deliberately not the 400-character prefix. */
        CROSS APPLY (SELECT CASE WHEN p.stmt_open > 0
                                 THEN SUBSTRING(w.st, p.stmt_open + 2,
                                          CASE WHEN p.rel_close > 1
                                               THEN p.rel_close - 1 ELSE 12000 END)
                            END AS body) bd
        CROSS APPLY dbo.fn_body_hash(bd.body) bh;

        /* --- 3. de-duplicate: N distinct values per shape -----------------
           Partitioned by body_hash, not by stmt_prefix. Under a prefix
           partition, every statement in a 192-member collision group shared
           one budget of @samples_per_shape, so the rarer members were starved
           of samples by the busier ones. */
        SELECT * INTO #sampled
        FROM (
            SELECT x.*,
                   ROW_NUMBER() OVER (PARTITION BY x.body_hash, x.value_segment
                                      ORDER BY x.event_id DESC) AS dup_rn,
                   DENSE_RANK()  OVER (PARTITION BY x.body_hash
                                       ORDER BY x.value_segment)  AS val_rank
            FROM #parsed x
            WHERE x.parse_status LIKE 'ok%'
        ) y
        WHERE y.dup_rn = 1 AND y.val_rank <= @samples_per_shape;

        /* --- 4. the dimension side of the key ----------------------------
           Filled here rather than in the query_stats collector so that an
           install of this script is self-sufficient, and so a row whose text
           was later re-captured in full gets a corrected hash. Cheap: a few
           thousand rows, and only the ones still missing it. */
        UPDATE qt
           SET body_hash = bh.body_hash
        FROM dbo.query_text qt
        CROSS APPLY (SELECT CONVERT(nvarchar(max), qt.query_text) AS qtext) q
        /* query_text stores some statements with a leading '(@P1 int,...)'
           declaration and some without, so the body does not start at a fixed
           offset. The declaration's closing parenthesis is the first ')'
           followed by a letter: the ones inside 'varchar(16)' are followed by
           ',' or ')'. */
        CROSS APPLY (SELECT CASE WHEN LEFT(q.qtext, 2) = N'(@'
                                  AND PATINDEX(N'%)[A-Za-z]%', q.qtext) > 0
                                 THEN PATINDEX(N'%)[A-Za-z]%', q.qtext) + 1
                                 ELSE 1 END AS body_start) bs
        CROSS APPLY dbo.fn_body_hash(SUBSTRING(q.qtext, bs.body_start, 12000)) bh
        WHERE qt.db_name = @db
          AND qt.body_hash IS NULL;
        SET @dim_filled = @@ROWCOUNT;

        /* --- 5. resolve each shape to a query_hash -----------------------
           Primary: exact equality on the whole-body hash.

           A unique candidate is still required. Two query_text rows can share
           a body_hash legitimately — a body over 12,000 characters, or a row
           whose text was captured truncated at 4,000 by an older collector and
           which therefore hashes as a prefix of the real thing. Where that
           happens the shape is left unmatched rather than bound to one of
           them: NULL is visible and countable, a wrong query_hash is neither.

           There is deliberately no prefix-based fallback. An earlier version
           matched on '(decl)' + the first 120 characters and took the first
           candidate; it was measured guessing on 127 of 733 shapes, and it
           spread the samples of the single most-executed query in the
           workload across 20 different query_hash values, only 3 of which
           landed on the right one. A fallback that is wrong a sixth of the
           time is worse than no fallback. */
        SELECT DISTINCT s.body_hash
        INTO #shapes
        FROM #sampled s;

        SELECT sh.body_hash, m.query_hash
        INTO #shape_hash
        FROM #shapes sh
        OUTER APPLY (
            SELECT CASE WHEN COUNT(DISTINCT qt.query_hash) = 1
                        THEN MIN(qt.query_hash) END AS query_hash
            FROM dbo.query_text qt
            WHERE qt.db_name   = @db
              AND qt.body_hash = sh.body_hash
        ) m;

        /* --- 6. store what is not already present ----------------------- */
        INSERT INTO dbo.param_sample
              (node_name, db_name, client_app_name, query_hash, body_hash,
               param_decl, stmt_prefix, value_segment, body_len,
               event_time_utc, duration_us, row_count, parse_status)
        SELECT @node, s.db_name, s.client_app_name, sh.query_hash, s.body_hash,
               s.param_decl, s.stmt_prefix, s.value_segment, s.body_len,
               s.event_time_utc, s.duration_us, s.row_count, s.parse_status
        FROM #sampled s
        LEFT JOIN #shape_hash sh ON sh.body_hash = s.body_hash
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.param_sample ps
             WHERE ps.body_hash = s.body_hash
               AND ISNULL(ps.value_segment, N'') = ISNULL(s.value_segment, N''));
        SET @rows = @@ROWCOUNT;

        /* Parse diagnostics land in collection_run rather than in silence. */
        DECLARE @diag nvarchar(2000);
        SELECT @diag = N'read=' + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #parsed))
                     + N' ok='  + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #parsed WHERE parse_status LIKE 'ok%'))
                     + N' shapes=' + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #shapes))
                     + N' unresolved=' + CONVERT(nvarchar(20), (SELECT COUNT(*) FROM #shape_hash WHERE query_hash IS NULL))
                     + N' dim_filled=' + CONVERT(nvarchar(20), @dim_filled)
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
