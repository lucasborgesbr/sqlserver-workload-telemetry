# SQL Server Workload Telemetry

*[Versão em português](README.pt-BR.md)*

Workload telemetry for SQL Server instances **without Query Store** — that is, anything older than SQL Server 2016, where the usual tooling simply does not apply.

It answers four questions about a live instance:

- Which queries run most often, and what do they cost in CPU?
- How long do they take, including the tail (p95/p99), not just the average?
- Which Agent jobs touch a given database, how long do they run, and **which runs actually did work** versus finishing in 0 seconds because there was nothing to process?
- What were the real parameter values, so replayable test cases can be derived?

Built for a migration baseline, but it works as general-purpose observability on a legacy instance.

> **Before you run this: it captures real parameter values.**
> `xe_workload.statement_text` will contain actual data from your production queries — customer names, identifiers, whatever your application passes as parameters. That is deliberate, because replayable test cases need real values, but it means the table is production data and possibly personal data. Read [Data sensitivity](#data-sensitivity) before deploying, and set `collect_statement = 0` if that trade is not acceptable in your environment.

## Scope and caveats

Honest about where this comes from: it was built and measured against **one** SQL Server 2014 SP3 Enterprise instance under a moderate OLTP workload. It works, and the design decisions are all backed by measurements — but those measurements are from that one instance.

Treat as starting points, not universal truths:

- **Collection intervals.** The 2-minute job-run interval exists because `sysjobhistory` on that instance kept about 11 minutes of history for its most frequent job. Yours may keep hours, or minutes.
- **Retention defaults and the sizing figures.** Event rate varies by orders of magnitude between instances. Derive your own with queries 1 and 10 after a week.
- **Guard step detection.** Off by default; it needs the pattern your own jobs use.
- **The `who_is_active` noise filter.** The `background`/`dormant`/DatabaseMail exclusions held on that instance. Check what your own samples actually contain before trusting the filter.

What generalises without qualification is the list of failure modes in [`docs/design-notes.md`](docs/design-notes.md). Those are properties of SQL Server, not of any one instance, and most of them fail silently.

## What it collects

| Stream | Table | Content | Interval | Default retention |
|---|---|---|---|---|
| Raw workload | `xe_workload` | Every batch and RPC: complete statement text **including parameter values**, duration, CPU, logical and physical reads, I/O writes, row count, app, host, login, session, and the originating job step | 5 min | 30 days |
| Aggregated query stats | `query_stat_delta` + `query_text` | Per-interval delta of executions, CPU, reads and writes by `query_hash` — the Query Store substitute | 5 min | 90 days |
| Job executions | `job_run`, view `vw_job_run_effective` | Real duration in seconds, status, guard-step flag, and `did_work` | 2 min | 365 days |
| Active request sampling | `who_is_active`, view `vw_who_is_active` | Long-running, blocked and blocking requests. Read it through the view: `sp_WhoIsActive` stamps its timestamp in **server local** time, and the view adds the UTC equivalent | 1 min | 30 days |
| Parameter values | `param_sample` | Real parameter values per query shape, pulled out of prepared-statement wrappers and reduced to compact rows — so nothing ever has to scan the workload table looking for values. Linked to its template by `body_hash`, a hash of the whole statement body | 1 h | 180 days |

Plus `collection_run`, an audit trail of every collector execution. That one matters more than it looks: without it, a gap in the data is indistinguishable from a collector that quietly died.

**Which table to use for what:**

- `query_stat_delta` + `query_text` → *what matters, what it costs, and the query's shape.* Weight comes from `delta_executions`; shape from `query_text`, which holds the complete parameterized statement with its parameter declaration prefix, e.g. `(@P1 varchar(16))SELECT ...`. Filter `counter_reset = 0` when summing — see the design notes for why.
- `xe_workload` → *the full statement as executed, with real parameter values.* This is the only source of actual values, and the only place to see what a client sent rather than what the engine cached.
- `param_sample` → *real parameter values, joinable to a weight.* Join it to `query_text` on `body_hash`, and from there to `query_stat_delta` on `query_hash`. **Filter `body_hash IS NOT NULL`** in anything that trusts the attribution: rows collected before that column existed were matched by text prefix, and on an ORM workload a prefix match is not merely incomplete — it binds values to the wrong statement. See the [migration](migrations/2026-09-22-match-by-body-hash.sql).

`xe_workload` itself has no `query_hash`, so it cannot be joined to the weights directly; that is a deliberate consequence of the granularity split described below, not an oversight. `param_sample` exists to bridge exactly that gap.

**They also see different things.** `query_stat_delta` records statements *inside* procedures and functions; `xe_workload` records only the *outer* call. A procedure invoked by a job appears in the former as one row per internal statement, and in the latter as a single batch whose text is just the `EXEC`. Searching `xe_workload` for a procedure's internal SQL returns nothing, and that is correct behaviour.

## What gets created

The full footprint on the instance, so you know what you are agreeing to before running `deploy.sql`:

- **One database** (`dba_telemetry` by default), `RECOVERY SIMPLE`, holding 12 tables and 3 views. Nothing is created in `master`, `msdb` or your application databases.
- **One server-scoped event session**, `Workload_Capture`, created stopped.
- **8 stored procedures and 1 inline function** (`fn_body_hash`, the single definition of the sample-to-template key), all in the telemetry database:

| Procedure | What it does |
|---|---|
| `usp_collect_query_stats` | Snapshots `sys.dm_exec_query_stats` and computes the delta against the previous snapshot, flagging counter resets so plan cache eviction never yields a negative |
| `usp_shred_xe_workload` | Reads the `.xel` set forward from a stored offset, shreds the XML, decodes the job GUID out of the Agent's `client_app_name`, and falls back to a full re-read if the offset went stale |
| `usp_collect_job_runs` | Copies new `sysjobhistory` rows, converting the HHMMSS duration and normalising timestamps to UTC |
| `usp_stamp_job_work` | Materializes `did_work` onto job rows while the source events still exist |
| `usp_collect_who_is_active` | Runs `sp_WhoIsActive` into a table, then strips the sessions that are alive but not working |
| `usp_refresh_job_inventory` | Rebuilds the map of which job steps touch a given database |
| `usp_collect_param_samples` | Samples real parameter values out of prepared-statement wrappers, reducing millions of LOB-bearing rows to a few thousand compact ones |
| `usp_purge_telemetry` | Batched retention deletes |

- **6 Agent jobs**, owned by the configured account:

| Job | Interval | Why that interval |
|---|---|---|
| `… - WhoIsActive` | 1 min | The smallest an Agent schedule allows. A sampler cannot measure short queries at all — this is here to catch what *lasts* |
| `… - Job Runs` | 2 min | `sysjobhistory` keeps only ~200 rows **per job**, so a frequent job may retain only minutes of history. A slow collector loses runs silently |
| `… - Query Stats` | 5 min | The engine aggregates these counters itself, so nothing is lost between collections |
| `… - XE Shred` | 5 min | The file target holds days of buffer; there is no urgency |
| `… - Param Samples` | 1 h | Each run accumulates coverage of rarer query shapes, so hourly converges instead of needing one big extraction |
| `… - Purge` | daily 04:00 | Retention, plus a refresh of the job inventory |

These jobs deliberately carry **no replica guard**, unlike the application jobs they often sit alongside — see [On an Availability Group](#on-an-availability-group).

## Retention

Applied by `usp_purge_telemetry`, which the daily job calls with no arguments so the configured defaults apply. Deletes are batched at 50,000 rows so a backlog does not become one long transaction.

| Table | Default | Cut-off column | |
|---|---|---|---|
| `xe_workload` | 30 days | `event_time_utc` | UTC |
| `who_is_active` | 30 days | `collection_time` | **server local** |
| `wia_collection` | follows `who_is_active` | — | the local-to-UTC map; a row lives as long as a sample references it |
| `query_stat_delta` | 90 days | `collected_at` | UTC |
| `job_run` | 365 days | `collected_at` | UTC |
| `param_sample` | 180 days | `collected_at` | UTC |
| `collection_run` | 60 days | `started_at` | UTC |
| `query_text`, `capture_residue_archive` | never | — | dimension and audit tables, negligible growth |

Two things worth understanding rather than just accepting:

**The UTC/local split is not sloppiness.** `sp_WhoIsActive` records `collection_time` in server local time and Extended Events records in UTC. The purge honours each column's own basis. Mixing them is the single most common way to get this kind of query wrong — see the design notes.

**`job_run` outliving `xe_workload` by 11 months only works because `did_work` is materialized** onto the row before the events expire. Without that, every run older than the workload window would report `did_work = 0`, indistinguishable from a genuine no-op — the exact opposite of what the flag is for.

## Requirements

- SQL Server 2014 or later. Written against 2014, so it avoids `CREATE OR ALTER`, `AT TIME ZONE`, `STRING_AGG` and Query Store throughout.
- `sysadmin`, or enough rights to create a database, an event session and Agent jobs.
- [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) installed in `master`. Not redistributed here; install it first.
- A writable directory for the Extended Events rollover files, ideally not on the data or log volume.
- `sqlcmd`, or SSMS with **SQLCMD Mode** enabled. The scripts use `:setvar`, which plain SSMS will not expand.

## Install

```bash
cp config.example.sql config.sql
# edit config.sql: database names, .xel path, job owner
sqlcmd -S <server> -E -I -b -i deploy.sql
```

`-I` is required — several scripts use XML methods, which need `QUOTED_IDENTIFIER ON`. `-b` stops on the first error. Run from the repository root, since `:r` resolves paths relative to the working directory.

The capture session is created but **not started**, so nothing is written until you say so:

```sql
ALTER EVENT SESSION [Workload_Capture] ON SERVER STATE = START;
```

Then wait a few minutes and run query 1 in [`queries/consumption.sql`](queries/consumption.sql) to confirm every collector is running clean.

Re-running `deploy.sql` is safe. Procedures and jobs are recreated in place; collected data is never touched.

### On an Availability Group

Deploy to **every replica**, not just the current primary. Event sessions are server-scoped, not AG-scoped, so a session that exists only on one node stops collecting the instant a failover happens — silently.

The telemetry database is deliberately kept **out** of the AG: monitoring data should not depend on the thing it monitors, and a database inside an AG is read-only on the secondary, which would stop a collector there from writing at all. Each node gets its own copy; `node_name` identifies the origin.

For the same reason, the Agent jobs created here carry **no replica guard**. A guard would mean the secondary never collects anything.

## Sizing

Measured on a moderately busy instance: about **12 events/second**, roughly **750 bytes per stored row**, which came to about **28 GB** at steady state under the default retention. Your mileage will differ by an order of magnitude in either direction, so derive it yourself: run queries 1 and 10 after a week and divide.

The `.xel` file target is capped in configuration (default 512 MB × 20 files = 10 GB) and cannot grow past it. Long-term history lives in the tables, not the files.

## Data sensitivity

`xe_workload.statement_text` contains **real parameter values from the monitored server**. Treat that table as production data, potentially including personal data.

- Do not commit extracts of it. `.gitignore` already excludes `*.csv`, `*.tsv` and `*.xel`.
- Tokenise before moving it off the server, including when deriving a benchmark suite from it.
- If that is unacceptable in your environment, set `collect_statement = 0` on `rpc_completed` in [`install/04_xevent_session.sql`](install/04_xevent_session.sql). You keep the timings and the I/O counters, and lose the replayability.

## Uninstall

```bash
sqlcmd -S <server> -E -I -b -v Confirm="YES" -i uninstall/99_teardown.sql
```

Drops the event session, the Agent jobs and the telemetry database. The `.xel` files must be deleted from the operating system afterwards — T-SQL cannot remove files without enabling `xp_cmdshell`, which this tool will not do. `sp_WhoIsActive` is left in place, since it was a prerequisite rather than something installed here.

## Read this before changing the filters

Three filtering decisions in [`install/04_xevent_session.sql`](install/04_xevent_session.sql) look like obvious optimisations and are not. Each is documented in the script itself and in [`docs/design-notes.md`](docs/design-notes.md):

1. **Do not add a positive database filter.** In Extended Events, `database_id` is the *session context*, not the object touched. A job step running in `master` and reaching your database by three-part name reports `database_id = 1` and would be dropped — silently.
2. **msdb is the one exclusion**, because it is mostly the Agent talking to itself, plus a Service Broker queue reader parked for minutes at a time that will wreck any percentile calculation.
3. **Do not filter on `writes = 0`.** `writes` counts I/O *pages*, not rows. Statements that modify cached pages report zero. Filtering on it discards most real work.

## Layout

```
config.example.sql      copy to config.sql and edit
deploy.sql              runs every install script in order
install/                01 schema · 02 collectors · 03 who_is_active
                        04 event session · 05 Agent jobs · 06 retention
migrations/             upgrades for installations made before a fix
uninstall/99_teardown   removes everything (guarded)
queries/consumption.sql 10 queries for reading the data
docs/design-notes.md    the traps, and why the design is what it is
```

## Licence

MIT. See [LICENSE](LICENSE).
