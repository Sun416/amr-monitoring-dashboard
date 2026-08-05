/* Read-only diagnosis after a client-side DWS refresh timeout. */
SET NOCOUNT ON;

SELECT TOP (10)
    b.batch_id,
    b.batch_start_time,
    b.batch_end_time,
    b.batch_status,
    b.error_message
FROM DWS.etl_batch AS b
ORDER BY b.batch_id DESC;

SELECT TOP (40)
    l.batch_id,
    l.target_table,
    l.load_status,
    l.affected_rows,
    l.error_message,
    l.load_start_time,
    l.load_end_time
FROM DWS.etl_load_log AS l
ORDER BY l.batch_id DESC, l.load_start_time DESC;

SELECT
    r.session_id,
    r.status,
    r.command,
    r.start_time,
    r.total_elapsed_time / 1000 AS elapsed_seconds,
    r.wait_type,
    r.wait_time / 1000 AS wait_seconds,
    r.blocking_session_id
FROM sys.dm_exec_requests AS r
WHERE r.database_id = DB_ID(N'IOT2020')
  AND r.session_id <> @@SPID;
