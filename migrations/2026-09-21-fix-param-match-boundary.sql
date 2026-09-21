/* ============================================================================
   Migration - parameter sampler: body/value boundary, and a match key that
               does not depend on the parameter declaration.

   WHO NEEDS THIS

   Anyone who installed the parameter sampler before this change. Two defects,
   both of which show up as param_sample.query_hash being NULL far more often
   than it should be, concentrated in SHORT statements.

   DEFECT 1 - the prefix ran past the end of the statement

   stmt_prefix was a fixed 400-character window over the statement body. When
   the body is shorter than that, the window runs past the closing quote of the
   body literal and swallows a parameter value:

     DELETE FROM reading WHERE reading.id = @P1',4104241
                                               ^^^^^^^^ value inside the key

   The value changes on every execution, so the key changes on every execution,
   so it never equals the stable template stored in query_text. The match fails
   by construction. Measured on the instance this was found on: every UPDATE
   body was 52-73 characters and every DELETE body 34-119, against a matching
   marker 120 characters wide -- so 100% of both failed to match, and the
   application's entire write path was missing from any weighted ranking.

   Note the threshold is the MARKER width, not the window width. A 400-char
   window only breaks the match when the pollution lands inside the first 120
   characters, which is why long SELECTs appeared to be fine.

   DEFECT 2 - the declaration is not stable, so it cannot be part of the key

   A prepared-statement client declares each parameter with the width of the
   value it is passing at that moment, so the same statement arrives as

     @P1 varchar(16)     on one execution
     @P1 varchar(34)     on the next

   and query_text holds whichever width happened to be in the plan cache. Any
   match key containing the declaration is therefore unstable. This one is
   easy to misread as "the sampler sees a new shape every time": measured here,
   6,269 INSERT samples produced 6,245 distinct shapes.

   query_text is also inconsistent about whether it stores the '(@P1 int)'
   declaration prefix at all, so the body does not start at a fixed offset.

   WHAT THIS DOES

   Part 1 replaces the procedure. Safe, no schema change, no reprocessing.
   Part 2 is an OPTIONAL backfill of rows already collected, and it rewrites
   stored columns, so it is guarded. Read the note before running it.
   ============================================================================ */

/* --- PART 1 - replace the collector ---------------------------------------
   Just re-run the install script; it drops and recreates the procedure and
   leaves collected data alone:

     sqlcmd -S <server> -E -I -b -i install/07_param_sampler.sql

   New rows are correct from the next run onward. Nothing else is required. */

/* --- PART 2 - OPTIONAL backfill of rows already collected -----------------

   Rows collected before the fix keep a polluted stmt_prefix and a NULL
   query_hash. The values themselves were never lost -- they are in
   value_segment -- so the only thing missing is the link to a weight.

   This matters if you need historical write-path weights. It is NOT needed to
   go forward.

   READ THIS FIRST:
     - It UPDATEs stmt_prefix in place. The clipped-off text is a parameter
       value which also exists in value_segment, so no information is lost,
       but the column no longer reads the same.
     - shape_value_hash is a PERSISTED computed column over stmt_prefix, so
       every touched row is recomputed. After clipping, rows that were
       distinct only because of their embedded values collapse to the same
       shape, leaving duplicates the collector would not have inserted. De-dup
       afterwards if that bothers you; nothing breaks either way.
     - Take a backup of the table first if the history matters to you.

   Run with:  sqlcmd ... -v Confirm="YES" -i this_file.sql
*/
:on error exit
GO
IF N'$(Confirm)' <> N'YES'
BEGIN
    PRINT 'Part 2 skipped. Re-run with -v Confirm="YES" to backfill.';
    PRINT 'Part 1 (replacing the procedure) is a separate step - see above.';
END
GO
IF N'$(Confirm)' = N'YES'
BEGIN
    SET NOCOUNT ON;
    DECLARE @clipped bigint, @matched bigint;

    /* Clip each polluted prefix at its own boundary. Masking '' with two
       non-quote characters preserves offsets; BIN2 keeps REPLACE length-exact. */
    UPDATE ps
       SET stmt_prefix = CAST(LEFT(ps.stmt_prefix, b.cut) AS nvarchar(400))
    FROM dbo.param_sample ps
    CROSS APPLY (SELECT CHARINDEX(N'''',
                     REPLACE(ps.stmt_prefix COLLATE Latin1_General_BIN2,
                             N'''''', NCHAR(1) + NCHAR(1))) AS q) x
    CROSS APPLY (SELECT CASE WHEN x.q > 1 THEN x.q - 1
                             ELSE LEN(ps.stmt_prefix) END AS cut) b
    WHERE ps.stmt_prefix LIKE N'%''%';
    SET @clipped = @@ROWCOUNT;

    /* Re-match the now-stable prefixes, declaration-independent, unique only. */
    SELECT qt.query_hash, q.qtext, bs.body_start,
           CAST(SUBSTRING(q.qtext, bs.body_start, 60) AS nvarchar(60)) AS body_head
    INTO #qt
    FROM dbo.query_text qt
    CROSS APPLY (SELECT CONVERT(nvarchar(max), qt.query_text) AS qtext) q
    CROSS APPLY (SELECT CASE WHEN LEFT(q.qtext, 2) = N'(@'
                              AND PATINDEX(N'%)[A-Za-z]%', q.qtext) > 0
                             THEN PATINDEX(N'%)[A-Za-z]%', q.qtext) + 1
                             ELSE 1 END AS body_start) bs;
    CREATE NONCLUSTERED INDEX ix_qt_head ON #qt (body_head);

    UPDATE ps
       SET query_hash = m.query_hash
    FROM dbo.param_sample ps
    CROSS APPLY (
        SELECT CASE WHEN COUNT(DISTINCT qt.query_hash) = 1
                    THEN MIN(qt.query_hash) END AS query_hash
        FROM #qt qt
        WHERE qt.body_head = CAST(SUBSTRING(ps.stmt_prefix, 1, 60) AS nvarchar(60))
          AND CHARINDEX(ps.stmt_prefix, qt.qtext) = qt.body_start
    ) m
    WHERE ps.query_hash IS NULL;
    SET @matched = @@ROWCOUNT;

    DROP TABLE #qt;
    PRINT 'prefixes clipped: ' + CONVERT(varchar(20), @clipped);
    PRINT 'rows newly matched to a query_hash: ' + CONVERT(varchar(20), @matched);
END
GO
