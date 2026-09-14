# Design notes and traps

*[Versão em português](design-notes.pt-BR.md)*

Every item here caused a real bug during development, and most of them fail **silently** — no error, just wrong data. They are written down so the next person does not have to rediscover them.

## Extended Events cannot write to a table

There is no table target. The available targets are `event_file`, `ring_buffer`, `histogram`, `event_counter` and `pair_matching`. So "XEvents into a table" always means:

```
session -> event_file (.xel) -> a job reads it with fn_xe_file_target_read_file
        -> shreds the XML -> INSERT into a table, resuming from a stored offset
```

The middle piece is the part people underestimate. It needs a bookmark, de-duplication, and a fallback for when the bookmark goes stale.

## database_id is the session context, not the object touched

This is the single most damaging misunderstanding available here.

In Extended Events, `sqlserver.database_id` reports the database context of the *session*, not the database whose objects the statement reads. A job step configured to run in `master` that reaches another database by three-part name reports `database_id = 1`.

Consequence: a session filtered to one application database silently drops all cross-database work aimed at it. In the case that produced this tool, a pilot session filtered that way missed a job running **every ten seconds** against the target database — roughly 100 executions during a 17-minute capture, zero events recorded, no error.

Capture without a positive database filter and filter offline, where the decision is reversible.

## writes counts pages, not rows

`writes` in `rpc_completed` and `sql_batch_completed` is a count of I/O **pages**, and it depends on buffer pool state and checkpoint timing. `row_count` counts rows.

Measured on a real instance: **17,099 events with `writes = 0` had touched 389,583 rows**, because the pages involved were already cached. Any filter or heuristic built on `writes` alone will therefore discard or misclassify most real work.

## dm_exec_sql_text returns the whole batch, not the statement

`sys.dm_exec_sql_text(sql_handle)` returns the entire batch text. For a statement inside a stored procedure or function, that is **the whole object definition** — the full `CREATE PROCEDURE` source, including any `DROP` preamble the author left in it.

Store that verbatim and `query_text` ends up holding the object's DDL instead of the query. Measured on a real instance before the fix: **19 of 21 procedure entries contained `CREATE PROCEDURE` / `CREATE FUNCTION` / `DROP PROCEDURE`** rather than a statement. The weights were right; the text next to them was useless.

The fix is the documented offset slice, which needs **both** offsets from the DMV:

```sql
SUBSTRING(st.text,
          (c.statement_start_offset / 2) + 1,
          ((CASE c.statement_end_offset
                 WHEN -1 THEN DATALENGTH(st.text)
                 ELSE c.statement_end_offset
            END - c.statement_start_offset) / 2) + 1)
```

The offsets are byte offsets into an `nvarchar`, hence the division by two. `statement_end_offset = -1` means "to the end of the batch".

One trap inside the trap: `MIN`/`MAX` do not accept `nvarchar(max)`, so an aggregate over the text does not compile. Working around that with `MIN(LEFT(st.text, 4000))` compiles fine and silently truncates — measured at **12.6% of templates** hitting the ceiling, concentrated in exactly the verbose ORM-generated queries most worth reading. Use `ROW_NUMBER()` to pick one row per hash instead of aggregating.

## counter_reset means the delta is not a delta

On a row where `counter_reset = 1`, the `delta_*` columns hold the **cumulative** value, not an interval difference. That is deliberate: it is how the collector avoids emitting negative deltas when a plan is recompiled or evicted from cache and the engine's counters restart.

The consequence is that `SUM(delta_executions)` without a filter double-counts. Measured on a real instance: **12% of rows were resets, inflating total executions by about 4% overall and up to 15% on individual templates.** Enough to reorder a ranking, not enough for anyone to notice.

Always filter:

```sql
AND counter_reset = 0
```

Note also which templates are most exposed: anything whose plan is invalidated on a schedule. A weekly `UPDATE STATISTICS ... WITH FULLSCAN` on a large table invalidates every plan touching it, so the procedures against that table carry the most reset rows — and those are usually the ones at the top of the ranking.

## did_work is a heuristic, and its definition matters

The goal is to distinguish a job run that processed something from one that finished in 0 seconds because its queue was empty. There is no flag for this — a conditional job whose work set is empty simply does nothing and reports success.

The signal used is: `row_count > 0 OR writes > 0`, aggregated over the events attributed to that job step within the run window.

| row_count | writes | Meaning |
|---|---|---|
| > 0 | 0 | Work whose pages were already cached — the common case |
| > 0 | > 0 | Work with physical writes |
| 0 | > 0 | `exec some_proc` batches, where the outer `row_count` reflects only the last statement |
| 0 | 0 | A genuine no-op |

Both halves are needed. A first attempt used `writes > 0` alone and misclassified hundreds of runs that had genuinely touched rows.

### Judge it at the run level, not the event level

**A single job run produces several batch events, not one.** Measured at six events per run for one job step: the actual work, plus protocol and `SET`-option batches that carry zero rows.

Counting zero-row events in `xe_workload` and calling them no-ops produced a confident "33% of runs did nothing" that was simply false — at run level, every captured run of that job had done work. Use `vw_job_run_effective`, which aggregates per run.

## Guard steps look like work

A common Availability Group pattern is a step 1 that aborts the job unless the local replica is primary, typically by raising an error. Two consequences:

- On a secondary, **every run is recorded as a failure**, and that is correct behaviour rather than an incident. Flagged as `is_secondary_noop`.
- The guard itself runs a query that returns rows, so `did_work` sees work. Flagged as `is_guard_step`.

Filter both out of any job analysis. `GuardStepPattern` in the config controls the detection.

## UTC versus local time

Extended Events timestamps are **UTC**. `msdb.dbo.agent_datetime()` returns **server local time**.

Correlating the two without normalising returns **zero matches and no error at all** — the join simply finds nothing, which reads as "this job did no work" rather than as a bug. This one cost real time to find.

`job_run.run_started_utc` is normalised at collection time and is the column the correlation joins on. SQL Server 2014 has no `AT TIME ZONE`, so the offset is captured with `DATEDIFF(minute, GETDATE(), GETUTCDATE())` when the row is written; historical DST boundaries are consequently approximate to within an hour.

## sysjobhistory has two traps

**`run_duration` is an integer formatted HHMMSS, not seconds.** `123` means 1 minute 23 seconds, not 123 seconds. Treating it as seconds understates short runs and wildly overstates long ones.

**Retention is roughly 200 rows per job**, controlled by an Agent property. That is generous for a nightly job and nearly useless for a frequent one: a job running every ten seconds keeps about **eleven minutes** of history. Any analysis of job duration needs its own collection, and the collector has to run often enough that it never falls outside that window. Hence the two-minute interval — five minutes would still fit, but a single delayed collection would lose runs silently.

## The shredder bookmark goes stale

`fn_xe_file_target_read_file` takes an initial file name and offset to resume from. Two ways that breaks:

1. **Rollover deletes the bookmarked file.** The stored offset no longer exists and the function raises error 25722. Without handling, the shredder is broken permanently, not transiently.
2. **The bookmark belongs to a different file set.** Pointing the shredder at another path while a global bookmark holds a file outside that pattern produces the same error. Hence `path_pattern` on the bookmark table.

The shredder catches the error, re-reads from the start of the available files, and relies on the de-duplication predicate to avoid double inserts. The fallback is recorded in `collection_run.error_message` while status stays `ok`, so it is visible without being alarming.

That de-duplication predicate needs an index on `(node_name, event_sequence, event_time_utc)`. Without it, shred time degrades badly as the table fills — measured going from 3 seconds to 46 seconds within a single day.

## A sampler cannot count queries

`sp_WhoIsActive` samples *currently active* requests. The probability of catching any given query is roughly its duration divided by the sampling interval. With a p99 in the low milliseconds and a one-minute interval, that is on the order of 0.01%.

So a sampler cannot answer "which queries run most" or "what is the typical latency" — those come from `query_stat_delta` and `xe_workload` respectively. What it does catch is what **lasts**: maintenance windows, integration jobs, blocking chains, anything pathological.

Also expect it to be dominated by sessions that are alive but not working — engine background workers, idle pooled connections, and Service Broker queue readers parked in `WAITFOR` for minutes at a time by design. It is filtered by **program name**, not by database, because excluding a whole database here would hide a genuinely stuck job in it.

## Watch for your own observer effect

Two flavours, both real:

**The collectors themselves.** Measured at 0.5% of captured events, so negligible — but worth confirming rather than assuming, with query 4.

**Your interactive sessions.** Diagnostic queries against a multi-million-row `xe_workload` — percentile calculations especially — turned out to be among the heaviest consumers on the instance: 20 minutes and 3.7 million milliseconds of CPU for a single query. Exclude your own client from outlier analysis, or you will find yourself at the top of your own list.

## Parked waits poison latency statistics

A Service Broker queue reader, or anything else sitting in `WAITFOR`, reports a duration of minutes with no cost and no work. One such event destroys a p99 or a maximum.

That is a large part of why msdb is excluded, but it is not exclusive to msdb — check any outlier for `cpu_time_us` near zero alongside a huge `duration_us` before concluding you have found a slow query.

## Parsing the sp_prepexec wrapper

A client using prepared statements does not send your query — it sends a wrapper around it:

```sql
declare @p1 int
set @p1=1
exec sp_prepexec @p1 output,
  N'@P1 datetime2',                          -- declaration
  N'SELECT ... WHERE x > @P1 ORDER BY ...',   -- body
  '2026-09-10 08:51:41.9837400'               -- values
select @p1                                    -- always last
```

Three consequences worth knowing before writing any analysis over this text:

**Roughly half the captured events carry no workload information.** Every prepare is matched by an `sp_unprepare`, which has no statement in it. Discard those before counting anything.

**Every execution produces a unique `statement_text`,** because the values are embedded in the wrapper. A naive `GROUP BY statement_text` therefore reports almost entirely single executions and looks like a long tail when it is not one.

**The wrapper is good news for replay, though.** It hands you the parameterised template, the parameter *types*, and a realistic value in one string — exactly what a replay harness needs.

Two traps if you parse it in T-SQL:

- **When the statement takes no parameters, `sp_prepexec` receives `NULL` in the declaration position.** The first `N'` you find is then the body, not a declaration. Extract it as the declaration and you will pull the whole query into a small column and get "String or binary data would be truncated" — which is the *good* outcome; the bad one is a column wide enough to accept it silently. A declaration always starts with `@`; check for it.
- **The body contains the word `select`,** so locating the wrapper's trailing `select @p1` must use the *last* occurrence, not the first. `REVERSE` plus `CHARINDEX` does it.

And know when to stop: statement bodies and values can both contain escaped single quotes, so fully delimiting the value list with `CHARINDEX` produces silent garbage on the cases it cannot handle. The right division of labour is to use SQL for the *volume reduction* — millions of LOB-bearing rows down to a few thousand compact ones — and do the final split wherever a real parser is available.

## Index keys have a 900-byte limit, and HASHBYTES lies about its width

Two natural keys in this kind of tooling exceed the limit: a file path plus offset, and a statement prefix plus value segment. The fix is to key on a hash instead, but there is a catch.

`HASHBYTES` is typed as `varbinary(8000)` regardless of the algorithm, even though `SHA2_256` always returns 32 bytes. A computed column over it therefore still trips the index key length check. Cast it explicitly:

```sql
ALTER TABLE dbo.example ADD shape_hash AS
    CAST(HASHBYTES('SHA2_256', ISNULL(a, N'') + N'|' + ISNULL(b, N'')) AS varbinary(32)) PERSISTED;
```

Note also that on SQL Server 2014 `HASHBYTES` rejects inputs over 8,000 bytes, so hash a bounded prefix rather than an `nvarchar(max)`.

## SQL Server 2014 syntax limits

Encountered while writing this, all applicable to 2014 and 2012:

- No `CREATE OR ALTER` (2016 SP1+). Every object is `DROP` then `CREATE`.
- No `AT TIME ZONE` (2016+). See the UTC section above.
- No Query Store (2016+). That is the whole reason this tool exists.
- `fn_xe_file_target_read_file` has no `timestamp_utc` column (2017+). The timestamp has to be shredded out of the event XML.
- Any query using XML methods needs `QUOTED_IDENTIFIER ON` — `sqlcmd -I`, or SSMS which sets it by default.
- The DMV column is `total_logical_writes`, not `total_writes`.
- `off` is a reserved keyword and cannot be used as a column alias.
- XML methods are not allowed in `GROUP BY`. Shred into a temp table first, then aggregate.
- `MIN`/`MAX` do not accept `nvarchar(max)`. `CONVERT` to a bounded type first.
- `bit` cannot be summed. `SUM(CONVERT(int, flag))`.
