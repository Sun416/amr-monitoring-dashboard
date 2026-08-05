USE [IOT2020];

/*
    Read-only preview for 64_install_dws_robot_live_state_view.sql.
    It validates the exact position, robot state and robot-reported job fields
    without creating any object. robot_job_history.job_name is not relabelled
    as a business task ID.
*/

SET NOCOUNT ON;

DECLARE
    @database_now DATETIME2(3) = SYSDATETIME(),
    @freshness_minutes INT = 10;

SELECT
    master_robot.[id] AS [master_robot_id],
    master_robot.[name] AS [robot_code],
    CASE
        WHEN status_row.[pc_timestamp] IS NULL THEN N'MISSING'
        WHEN DATEDIFF(MINUTE, status_row.[pc_timestamp], @database_now) > @freshness_minutes THEN N'TIMEOUT'
        ELSE N'CURRENT'
    END AS [status_freshness_status],
    CASE
        WHEN status_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN status_row.[robot_move_state]
    END AS [current_status],
    CASE
        WHEN status_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN status_row.[robot_current_map]
    END AS [map_code],
    CASE
        WHEN status_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN status_row.[robot_position_x]
    END AS [position_x],
    CASE
        WHEN status_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN status_row.[robot_position_y]
    END AS [position_y],
    status_row.[pc_timestamp] AS [status_event_time],
    DATEDIFF(MINUTE, status_row.[pc_timestamp], @database_now) AS [status_data_age_minutes],
    CASE
        WHEN job_row.[pc_timestamp] IS NULL THEN N'MISSING'
        WHEN DATEDIFF(MINUTE, job_row.[pc_timestamp], @database_now) > @freshness_minutes THEN N'TIMEOUT'
        ELSE N'CURRENT'
    END AS [job_freshness_status],
    CASE
        WHEN job_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN job_row.[source_job_history_row_id]
    END AS [source_job_history_row_id],
    CASE
        WHEN job_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN job_row.[job_name]
    END AS [robot_reported_job_name],
    CASE
        WHEN job_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN job_row.[job_status]
    END AS [robot_job_status],
    CASE
        WHEN job_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN job_row.[poi_current]
    END AS [current_station_code],
    CASE
        WHEN job_row.[pc_timestamp] >= DATEADD(MINUTE, -@freshness_minutes, @database_now)
            THEN job_row.[poi_target]
    END AS [target_station_code],
    job_row.[pc_timestamp] AS [job_event_time],
    DATEDIFF(MINUTE, job_row.[pc_timestamp], @database_now) AS [job_data_age_minutes],
    @database_now AS [database_current_time]
FROM [dbo].[MA_AMR] AS master_robot
OUTER APPLY (
    SELECT TOP (1)
        status_source.[pc_timestamp],
        status_source.[robot_move_state],
        status_source.[robot_current_map],
        status_source.[robot_position_x],
        status_source.[robot_position_y]
    FROM [dbo].[robot_status_history] AS status_source
        WITH (INDEX([IX_status_performance]), FORCESEEK)
    WHERE status_source.[amr_id] = master_robot.[id]
    ORDER BY status_source.[pc_timestamp] DESC
) AS status_row
OUTER APPLY (
    SELECT TOP (1)
        job_source.[id] AS [source_job_history_row_id],
        job_source.[pc_timestamp],
        job_source.[job_name],
        job_source.[job_status],
        job_source.[poi_current],
        job_source.[poi_target]
    FROM [dbo].[robot_job_history] AS job_source
        WITH (INDEX([IX_job_performance]), FORCESEEK)
    WHERE job_source.[amr_id] = master_robot.[id]
    ORDER BY job_source.[pc_timestamp] DESC
) AS job_row
WHERE UPPER(LTRIM(RTRIM(COALESCE(master_robot.[is_active], N'')))) = N'Y'
ORDER BY master_robot.[name], master_robot.[id];
