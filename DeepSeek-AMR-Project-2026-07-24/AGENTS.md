# Database Development Instructions

## Startup Context

- Read `PROJECT_STATUS_COMPACT.md` first for the current AMR warehouse and Web status.
- Treat it as the compact continuation point; do not reconstruct the project from the long conversation unless a legacy failure must be investigated.
- Re-verify volatile facts such as row counts, source timestamps, online robots, batch status, and permissions before acting.

## Project Scope

- This workspace is for Microsoft SQL Server database analysis and development.
- Treat `IOT2020` as the expected target database unless the user specifies another database.
- The common warehouse layers are `ODS`, `DWD`, `DWS`, and `ADS`.
- Prefer read-only inspection and preview SQL before proposing write operations.
- Do not execute destructive or broad data-changing statements unless the user explicitly approves the exact operation.

## SQL Server Defaults

- Use T-SQL syntax.
- Do not assume the SQL Server version or database compatibility level.
- Use schema-qualified object names such as `ODS.TableName`, `DWD.TableName`, or `dbo.TableName`.
- Use explicit column lists. Do not use `SELECT *` in production or reviewable SQL.
- Use explicit `JOIN` syntax and qualify joined fields with table aliases.
- Prefix Chinese `NVARCHAR` string literals with `N`, for example `N'<Chinese text>'`.
- Use `[square brackets]` for identifiers only when needed for reserved words, special characters, or collision risk.
- Prefer parameterized SQL over string concatenation.
- Do not use `NOLOCK` by default.
- Do not add `DISTINCT` merely to hide duplicate rows caused by incorrect joins.
- Do not use `MERGE` automatically; first evaluate concurrency, duplicate match, and correctness risks.

## Safety Rules

- For every nontrivial `UPDATE` or `DELETE`, provide a matching `SELECT` preview first.
- Never run or recommend these without explaining scope and impact:
  - `DROP`
  - `TRUNCATE`
  - `DELETE` without a selective `WHERE`
  - `UPDATE` without a selective `WHERE`
  - large backfills or repairs
- Prefer transaction-wrapped repair scripts with:
  - `SET XACT_ABORT ON`
  - `TRY/CATCH`
  - explicit `BEGIN TRANSACTION`, `COMMIT`, and rollback handling
- Avoid one huge transaction for high-volume backfills unless log growth, blocking, and rollback duration have been evaluated.
- Migration or repair scripts should include validation and a rollback or recovery strategy.

## Data Warehouse And ETL Rules

- Preserve source-system traceability where possible.
- For `ODS` to `DWD` synchronization, identify source keys, ingestion timestamps, and load provenance columns before writing repair SQL.
- Incremental loading logic must define:
  - watermark column
  - lower and upper boundaries
  - duplicate handling
  - late-arriving record handling
  - retry behavior
  - transaction boundaries
- Prefer left-closed, right-open time windows:

```sql
WHERE update_time >= @start_time
  AND update_time <  @end_time;
```

- Do not invent missing table names, column names, primary keys, constraints, or data types. Inspect local files or ask for details.

## Performance Review

When reviewing or writing SQL, check:

- join predicates and duplicate amplification
- NULL handling and three-valued logic
- implicit conversions
- non-SARGable predicates
- functions applied to indexed columns
- full scans versus seeks
- key lookups
- excessive sorts, hashes, cursors, temp tables, or scalar functions
- parameter sniffing and data skew
- statistics and cardinality estimates
- blocking, deadlock, and transaction-log impact

When proposing an index, include:

- full `CREATE INDEX` statement
- key columns
- included columns
- expected read benefit
- write cost for `INSERT`, `UPDATE`, and `DELETE`
- overlap with existing indexes, if known

## Required Response Shape For SQL Work

For nontrivial SQL generation or review, respond with:

1. SQL code
2. Execution logic
3. Possible risks
4. Suggested indexes
5. Pre-execution validation method

For code review, lead with concrete findings ordered by severity. Separate correctness risks from performance risks.
