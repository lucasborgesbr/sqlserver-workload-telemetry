/* ============================================================================
   Migration - link parameter samples to query_hash by whole-body hash instead
               of by text prefix.

   WHO NEEDS THIS

   Anyone whose parameter sampler matched samples to query_text by comparing a
   PREFIX of the statement text. That approach does not just fail to match, it
   matches the WRONG statement, and the result looks correct.

   WHY A PREFIX CANNOT WORK

   An ORM emits many statements over the same table with the same expanded
   column list, diverging only at the JOIN, the WHERE or the ORDER BY -- all of
   which sit past any reasonable prefix. Measured on the instance this was
   found on:

     - 89% of bodies longer than 400 characters share their first 400
       characters with another statement; the largest such group holds 192
       distinct queries.
     - 71% of bodies longer than 4,000 characters still collide at 4,000.
     - The single most-executed query in the workload had its samples spread
       across 20 different query_hash values, only 3 of which were correct.

   Widening the prefix does not fix this, it only moves it. The key has to be
   the whole body.

   WHAT THIS CHANGES

     - dbo.fn_body_hash: one definition of the key, used on both sides.
     - param_sample.body_hash, query_text.body_hash, plus an index on each.
     - param_sample.body_len, so a truncated stmt_prefix is visible.
     - parse_status gains 'ok_prefix_cut' for rows whose body exceeds the
       prefix width. Informational: matching does not use the prefix.
     - De-duplication keys on (body_hash, value_segment) rather than on
       (stmt_prefix, value_segment). Under the old key, every statement in a
       collision group shared one @samples_per_shape budget, so rarer members
       were starved by busier ones.
     - The prefix-based fallback match is REMOVED rather than tightened.

   Apply by re-running the install script; it is idempotent and adds the
   columns if they are missing:

     sqlcmd -S <server> -E -I -b -i install/07_param_sampler.sql

   ============================================================================
   IMPORTANT - ROWS COLLECTED BEFORE THIS CANNOT BE REPAIRED IN PLACE

   A historical row stored only a truncated prefix, so the full body it came
   from is not recoverable from param_sample. Those rows keep body_hash NULL,
   and for any statement longer than the old prefix width their query_hash is
   UNRELIABLE -- not missing, wrong.

   So the trustworthy-row predicate is:

       WHERE body_hash IS NOT NULL

   Use it in anything that joins param_sample to a weight. Three ways forward,
   in order of preference:

     1. Filter on body_hash IS NOT NULL and let the collector accumulate. It
        converges quickly, since it samples per shape rather than per event.
     2. Re-derive history from xe_workload for whatever window you still
        retain. The events hold the complete wrapper; this script does not do
        it for you because the right window is a local decision.
     3. Delete the pre-fix rows, if a table where every row is trustworthy is
        worth more to you than an unreliable history. Guarded below.
   ============================================================================ */

/* --- OPTIONAL - discard the rows whose attribution cannot be trusted ------
   Run with:  sqlcmd ... -v Confirm="YES" -i this_file.sql
   Deletes only rows with no body_hash, i.e. those collected before the fix.
   Batched so a large backlog does not become one long transaction. */
:on error exit
GO
IF N'$(Confirm)' <> N'YES'
BEGIN
    PRINT 'No rows deleted. Re-run with -v Confirm="YES" to discard pre-fix rows.';
    PRINT 'Re-running install/07_param_sampler.sql is the actual migration.';
END
GO
IF N'$(Confirm)' = N'YES'
BEGIN
    SET NOCOUNT ON;
    DECLARE @n int = 1, @total bigint = 0;
    WHILE @n > 0
    BEGIN
        DELETE TOP (50000) FROM dbo.param_sample WHERE body_hash IS NULL;
        SET @n = @@ROWCOUNT;
        SET @total = @total + @n;
    END
    PRINT 'pre-fix rows discarded: ' + CONVERT(varchar(20), @total);
END
GO
