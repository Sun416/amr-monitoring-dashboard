USE IOT2020;
GO

/*
    Manual historical-pipeline test.
    The current full DWS aggregation previously took several minutes.
*/

DECLARE @started_at DATETIME2(3) = SYSDATETIME();

EXEC [DWS].[sp_run_amr_historical_pipeline];

SELECT
    @started_at AS [started_at],
    SYSDATETIME() AS [finished_at],
    DATEDIFF(SECOND, @started_at, SYSDATETIME()) AS [elapsed_seconds];

SELECT TOP (5)
    [batch_id], [batch_start_time], [batch_end_time], [batch_status], [error_message]
FROM [DWD].[etl_batch]
WHERE [batch_start_time] >= @started_at
ORDER BY [batch_id] DESC;

SELECT TOP (5)
    [batch_id], [batch_start_time], [batch_end_time], [batch_status], [error_message]
FROM [DWS].[etl_batch]
WHERE [batch_start_time] >= @started_at
ORDER BY [batch_id] DESC;

SELECT
    [load_mode], [load_status], COUNT_BIG(*) AS [log_row_count],
    SUM(ISNULL([affected_rows], 0)) AS [affected_rows]
FROM [DWS].[etl_load_log]
WHERE [load_start_time] >= @started_at
GROUP BY [load_mode], [load_status]
ORDER BY [load_status], [load_mode];
GO
