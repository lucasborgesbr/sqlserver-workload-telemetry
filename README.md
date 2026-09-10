# SQL Server Workload Telemetry

*[Versão em português](README.pt-BR.md)*

Workload telemetry for SQL Server instances **without Query Store** — that is, anything older than SQL Server 2016, where the usual tooling simply does not apply.

It answers four questions about a live instance:

- Which queries run most often, and what do they cost in CPU?
- How long do they take, including the tail (p95/p99), not just the average?
- Which Agent jobs touch a given database, how long do they run, and **which runs actually did work** versus finishing in 0 seconds because there was nothing to process?
- What were the real parameter values, so replayable test cases can be derived?

Built for a migration baseline, but it works as general-purpose observability on a legacy instance.

## What it collects

| Stream | Table | Content | Interval | Default retention |
|---|---|---|---|---|
| Raw workload | `xe_workload` | Every batch and RPC: complete statement text **including parameter values**, duration, CPU, logical and physical reads, I/O writes, row count, app, host, login, session, and the originating job step | 5 min | 30 days |
| Aggregated query stats | `query_stat_delta` + `query_text` | Per-interval delta of executions, CPU, reads and writes by `query_hash` — the Query Store substitute | 5 min | 90 days |
| Job executions | `job_run`, view `vw_job_run_effective` | Real duration in seconds, status, guard-step flag, and `did_work` | 2 min | 365 days |
| Active request sampling | `who_is_active` | Long-running, blocked and blocking requests | 1 min | 30 days |

Plus `collection_run`, an audit trail of every collector execution. That one matters more than it looks: without it, a gap in the data is indistinguishable from a collector that quietly died.

**Which table to use for what:** `query_stat_delta` tells you *what matters and what it costs*; `xe_workload` holds *the full text with the actual values*. `query_text` is a labelling dimension, truncated at 4,000 characters — it is not a source of complete queries.

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
uninstall/99_teardown   removes everything (guarded)
queries/consumption.sql 10 queries for reading the data
docs/design-notes.md    the traps, and why the design is what it is
```

## Licence

MIT. See [LICENSE](LICENSE).
