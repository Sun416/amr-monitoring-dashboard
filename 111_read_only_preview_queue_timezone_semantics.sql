USE [IOT2020];

/*
  Read-only assessment of AMR_Queue.enqueued_at timezone handling.
  A +00:00 source value is an instant in UTC. SWITCHOFFSET preserves that
  instant while presenting it in Thailand's fixed +07:00 offset.
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

SELECT
    schema_row.[name] AS [schema_name],
    table_row.[name] AS [table_name],
    column_row.[name] AS [column_name],
    type_row.[name] AS [data_type],
    column_row.[max_length],
    column_row.[scale]
FROM sys.columns AS column_row
INNER JOIN sys.tables AS table_row
    ON table_row.[object_id] = column_row.[object_id]
INNER JOIN sys.schemas AS schema_row
    ON schema_row.[schema_id] = table_row.[schema_id]
INNER JOIN sys.types AS type_row
    ON type_row.[user_type_id] = column_row.[user_type_id]
WHERE
(
    schema_row.[name] IN (N'dbo', N'ODS')
    AND table_row.[name] = N'AMR_Queue'
    AND column_row.[name] = N'enqueued_at'
)
OR
(
    schema_row.[name] = N'DWD'
    AND table_row.[name] = N'fact_amr_queue'
    AND column_row.[name] IN (N'event_time', N'queue_start_time')
)
ORDER BY schema_row.[name], table_row.[name], column_row.[column_id];

SELECT TOP (20)
    source_row.[ods_row_id],
    source_row.[enqueued_at] AS [source_enqueued_at],
    TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]) AS [source_instant_with_offset],
    SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]), N'+07:00') AS [thailand_instant_with_offset],
    CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]), N'+07:00')) AS [thailand_local_datetime],
    queue_fact.[event_time] AS [current_dwd_event_time],
    queue_fact.[queue_start_time] AS [current_dwd_queue_start_time],
    DATEDIFF
    (
        MINUTE,
        CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]), N'+07:00')),
        queue_fact.[queue_start_time]
    ) AS [current_dwd_minus_thailand_minutes]
FROM [ODS].[AMR_Queue] AS source_row
INNER JOIN [DWD].[fact_amr_queue] AS queue_fact
    ON queue_fact.[source_schema] = N'ODS'
   AND queue_fact.[source_table] = N'AMR_Queue'
   AND queue_fact.[source_ods_row_id] = source_row.[ods_row_id]
WHERE TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]) IS NOT NULL
ORDER BY source_row.[ods_row_id] DESC;

SELECT
    COUNT_BIG(*) AS [comparable_row_count],
    SUM(CASE WHEN queue_fact.[queue_start_time] = CONVERT(DATETIME2(3), SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]), N'+07:00')) THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [already_thailand_local_count],
    SUM(CASE WHEN queue_fact.[queue_start_time] = CONVERT(DATETIME2(3), TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at])) THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [utc_clock_time_stored_count],
    SUM(CASE WHEN queue_fact.[queue_start_time] IS NULL THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS [null_dwd_queue_start_count]
FROM [ODS].[AMR_Queue] AS source_row
INNER JOIN [DWD].[fact_amr_queue] AS queue_fact
    ON queue_fact.[source_schema] = N'ODS'
   AND queue_fact.[source_table] = N'AMR_Queue'
   AND queue_fact.[source_ods_row_id] = source_row.[ods_row_id]
WHERE TRY_CONVERT(DATETIMEOFFSET(7), source_row.[enqueued_at]) IS NOT NULL;
