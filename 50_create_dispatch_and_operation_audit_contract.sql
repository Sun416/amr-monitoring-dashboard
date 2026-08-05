/*
    Unified AMR event and audit contract
    ====================================

    Creates:
      - DWD.fact_robot_operation_event
      - DWD.fact_dispatch_decision_candidate
      - DWD.fact_robot_incident
      - DWD.fact_robot_incident_evidence
      - DWD.robot_event_watermark
      - DWS.v_robot_event_audit_coverage

    This installer is non-destructive:
      - no source rows are changed;
      - no existing rows are deleted or updated;
      - tables are created only when absent.

    Source loading is installed separately by script 52.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'IOT2020'
BEGIN
    THROW 55000, N'Expected database IOT2020.', 1;
END;

IF SCHEMA_ID(N'DWD') IS NULL OR SCHEMA_ID(N'DWS') IS NULL
BEGIN
    THROW 55001, N'DWD and DWS schemas must already exist.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'[DWD].[robot_event_watermark]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[robot_event_watermark] (
            [source_schema] SYSNAME NOT NULL,
            [source_table] SYSNAME NOT NULL,
            [watermark_column] SYSNAME NOT NULL,
            [last_ods_row_id] BIGINT NOT NULL
                CONSTRAINT [DF_robot_event_watermark_last_id] DEFAULT (0),
            [last_event_time] DATETIME2(3) NULL,
            [last_success_time] DATETIME2(3) NULL,
            [last_batch_id] BIGINT NULL,
            [last_source_row_count] BIGINT NOT NULL
                CONSTRAINT [DF_robot_event_watermark_source_count] DEFAULT (0),
            [last_inserted_event_count] BIGINT NOT NULL
                CONSTRAINT [DF_robot_event_watermark_event_count] DEFAULT (0),
            [updated_at] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_robot_event_watermark_updated_at] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_robot_event_watermark]
                PRIMARY KEY CLUSTERED ([source_schema], [source_table])
        );
    END;

    IF OBJECT_ID(N'[DWD].[fact_robot_operation_event]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[fact_robot_operation_event] (
            [operation_event_fact_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [event_time] DATETIME2(3) NOT NULL,
            [event_category] NVARCHAR(50) NOT NULL,
            [event_type] NVARCHAR(100) NOT NULL,
            [event_status] NVARCHAR(100) NULL,
            [task_id] NVARCHAR(100) NULL,
            [queue_id] NVARCHAR(100) NULL,
            [job_id] NVARCHAR(100) NULL,
            [subjob_id] NVARCHAR(100) NULL,
            [robot_id] NVARCHAR(100) NULL,
            [robot_code] NVARCHAR(100) NULL,
            [project_id] NVARCHAR(100) NULL,
            [priority] INT NULL,
            [route_id] NVARCHAR(100) NULL,
            [route_segment_id] NVARCHAR(100) NULL,
            [station_code] NVARCHAR(100) NULL,
            [map_code] NVARCHAR(100) NULL,
            [position_x] DECIMAL(18, 6) NULL,
            [position_y] DECIMAL(18, 6) NULL,
            [battery_soc] DECIMAL(9, 2) NULL,
            [event_value] NVARCHAR(500) NULL,
            [event_value_numeric] DECIMAL(18, 6) NULL,
            [source_schema] SYSNAME NOT NULL,
            [source_table] SYSNAME NOT NULL,
            [source_ods_row_id] BIGINT NOT NULL,
            [source_event_part] NVARCHAR(50) NOT NULL,
            [source_event_time] DATETIME2(3) NOT NULL,
            [source_ods_load_time] DATETIME2(3) NULL,
            [dwd_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_fact_robot_operation_event_load_time] DEFAULT SYSDATETIME(),
            [dwd_batch_id] BIGINT NOT NULL,
            CONSTRAINT [PK_fact_robot_operation_event]
                PRIMARY KEY CLUSTERED ([operation_event_fact_id])
        );

        CREATE UNIQUE NONCLUSTERED INDEX [UX_fact_robot_operation_event_source]
            ON [DWD].[fact_robot_operation_event] (
                [source_schema],
                [source_table],
                [source_ods_row_id],
                [source_event_part]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_operation_event_robot_time]
            ON [DWD].[fact_robot_operation_event] (
                [robot_id],
                [event_time],
                [event_type]
            )
            INCLUDE (
                [task_id],
                [queue_id],
                [job_id],
                [subjob_id],
                [event_status],
                [event_value_numeric]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_operation_event_task_time]
            ON [DWD].[fact_robot_operation_event] (
                [task_id],
                [event_time],
                [event_type]
            )
            INCLUDE (
                [robot_id],
                [queue_id],
                [job_id],
                [subjob_id],
                [event_status]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_operation_event_type_time]
            ON [DWD].[fact_robot_operation_event] (
                [event_type],
                [event_time]
            )
            INCLUDE (
                [robot_id],
                [robot_code],
                [task_id],
                [event_status],
                [source_table]
            );
    END;

    IF OBJECT_ID(N'[DWD].[fact_dispatch_decision_candidate]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[fact_dispatch_decision_candidate] (
            [dispatch_candidate_fact_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [decision_id] NVARCHAR(100) NOT NULL,
            [task_id] NVARCHAR(100) NOT NULL,
            [decision_time] DATETIME2(3) NOT NULL,
            [robot_id] NVARCHAR(100) NOT NULL,
            [robot_code] NVARCHAR(100) NULL,
            [project_id] NVARCHAR(100) NULL,
            [priority] INT NULL,
            [candidate_rank] INT NULL,
            [eligibility_result] BIT NOT NULL,
            [eligibility_reason_code] NVARCHAR(100) NULL,
            [eligibility_reason_message] NVARCHAR(500) NULL,
            [total_score] DECIMAL(18, 6) NULL,
            [distance_score] DECIMAL(18, 6) NULL,
            [workload_score] DECIMAL(18, 6) NULL,
            [battery_score] DECIMAL(18, 6) NULL,
            [queue_score] DECIMAL(18, 6) NULL,
            [selected_flag] BIT NOT NULL,
            [rejection_reason_code] NVARCHAR(100) NULL,
            [rejection_reason_message] NVARCHAR(500) NULL,
            [source_schema] SYSNAME NOT NULL,
            [source_table] SYSNAME NOT NULL,
            [source_event_id] NVARCHAR(200) NOT NULL,
            [source_event_time] DATETIME2(3) NOT NULL,
            [dwd_load_time] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_fact_dispatch_candidate_load_time] DEFAULT SYSDATETIME(),
            [dwd_batch_id] BIGINT NULL,
            CONSTRAINT [PK_fact_dispatch_decision_candidate]
                PRIMARY KEY CLUSTERED ([dispatch_candidate_fact_id]),
            CONSTRAINT [CK_fact_dispatch_candidate_selection]
                CHECK ([selected_flag] = 0 OR [eligibility_result] = 1)
        );

        CREATE UNIQUE NONCLUSTERED INDEX [UX_fact_dispatch_candidate_decision_robot]
            ON [DWD].[fact_dispatch_decision_candidate] (
                [decision_id],
                [robot_id]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_dispatch_candidate_source]
            ON [DWD].[fact_dispatch_decision_candidate] (
                [source_schema],
                [source_table],
                [source_event_time]
            )
            INCLUDE (
                [source_event_id],
                [decision_id],
                [robot_id],
                [selected_flag]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_dispatch_candidate_decision_time]
            ON [DWD].[fact_dispatch_decision_candidate] (
                [decision_time],
                [decision_id],
                [selected_flag]
            )
            INCLUDE (
                [task_id],
                [robot_id],
                [robot_code],
                [eligibility_result],
                [total_score],
                [rejection_reason_code]
            );
    END;

    IF OBJECT_ID(N'[DWD].[fact_robot_incident]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[fact_robot_incident] (
            [incident_fact_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [incident_key] NVARCHAR(200) NOT NULL,
            [robot_id] NVARCHAR(100) NOT NULL,
            [robot_code] NVARCHAR(100) NULL,
            [incident_type] NVARCHAR(100) NOT NULL,
            [rule_id] NVARCHAR(100) NOT NULL,
            [opened_at] DATETIME2(3) NOT NULL,
            [last_observed_at] DATETIME2(3) NOT NULL,
            [closed_at] DATETIME2(3) NULL,
            [incident_status] NVARCHAR(30) NOT NULL,
            [severity] NVARCHAR(30) NOT NULL,
            [confidence] NVARCHAR(30) NOT NULL,
            [diagnosis] NVARCHAR(1000) NOT NULL,
            [confirmed_cause_code] NVARCHAR(100) NULL,
            [confirmed_cause_message] NVARCHAR(1000) NULL,
            [resolution_action] NVARCHAR(1000) NULL,
            [confirmed_by] NVARCHAR(200) NULL,
            [confirmed_at] DATETIME2(3) NULL,
            [created_at] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_fact_robot_incident_created_at] DEFAULT SYSDATETIME(),
            [updated_at] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_fact_robot_incident_updated_at] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_fact_robot_incident]
                PRIMARY KEY CLUSTERED ([incident_fact_id]),
            CONSTRAINT [UX_fact_robot_incident_key]
                UNIQUE NONCLUSTERED ([incident_key]),
            CONSTRAINT [CK_fact_robot_incident_status]
                CHECK ([incident_status] IN (N'OPEN', N'CONFIRMED', N'RESOLVED'))
        );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_incident_robot_opened]
            ON [DWD].[fact_robot_incident] (
                [robot_id],
                [opened_at]
            )
            INCLUDE (
                [incident_status],
                [rule_id],
                [severity],
                [confidence],
                [confirmed_cause_code]
            );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_incident_status_time]
            ON [DWD].[fact_robot_incident] (
                [incident_status],
                [last_observed_at]
            )
            INCLUDE (
                [robot_id],
                [robot_code],
                [rule_id],
                [severity]
            );
    END;

    IF OBJECT_ID(N'[DWD].[fact_robot_incident_evidence]', N'U') IS NULL
    BEGIN
        CREATE TABLE [DWD].[fact_robot_incident_evidence] (
            [incident_evidence_fact_id] BIGINT IDENTITY(1, 1) NOT NULL,
            [incident_fact_id] BIGINT NOT NULL,
            [evidence_time] DATETIME2(3) NOT NULL,
            [evidence_type] NVARCHAR(100) NOT NULL,
            [evidence_name] NVARCHAR(200) NOT NULL,
            [evidence_value] NVARCHAR(2000) NULL,
            [evidence_value_numeric] DECIMAL(18, 6) NULL,
            [evidence_unit] NVARCHAR(50) NULL,
            [source_schema] SYSNAME NULL,
            [source_table] SYSNAME NULL,
            [source_row_id] NVARCHAR(200) NULL,
            [source_freshness_seconds] BIGINT NULL,
            [captured_at] DATETIME2(3) NOT NULL
                CONSTRAINT [DF_fact_robot_incident_evidence_captured_at] DEFAULT SYSDATETIME(),
            CONSTRAINT [PK_fact_robot_incident_evidence]
                PRIMARY KEY CLUSTERED ([incident_evidence_fact_id]),
            CONSTRAINT [FK_fact_robot_incident_evidence_incident]
                FOREIGN KEY ([incident_fact_id])
                REFERENCES [DWD].[fact_robot_incident] ([incident_fact_id])
        );

        CREATE NONCLUSTERED INDEX [IX_fact_robot_incident_evidence_incident_time]
            ON [DWD].[fact_robot_incident_evidence] (
                [incident_fact_id],
                [evidence_time],
                [evidence_type]
            )
            INCLUDE (
                [evidence_name],
                [evidence_value],
                [evidence_value_numeric],
                [source_table]
            );
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;

EXEC sys.sp_executesql N'
CREATE OR ALTER VIEW [DWS].[v_robot_event_audit_coverage]
AS
SELECT
    operation_event.[source_schema],
    operation_event.[source_table],
    operation_event.[event_category],
    operation_event.[event_type],
    COUNT_BIG(1) AS [event_count],
    COUNT_BIG(operation_event.[robot_id]) AS [robot_attributed_event_count],
    MIN(operation_event.[event_time]) AS [first_event_time],
    MAX(operation_event.[event_time]) AS [latest_event_time],
    MAX(operation_event.[dwd_load_time]) AS [latest_load_time]
FROM [DWD].[fact_robot_operation_event] AS operation_event
GROUP BY
    operation_event.[source_schema],
    operation_event.[source_table],
    operation_event.[event_category],
    operation_event.[event_type];
';

SELECT
    schema_info.[name] AS [schema_name],
    table_info.[name] AS [table_name],
    SUM(partition_stats.[row_count]) AS [row_count]
FROM [sys].[tables] AS table_info
INNER JOIN [sys].[schemas] AS schema_info
    ON schema_info.[schema_id] = table_info.[schema_id]
INNER JOIN [sys].[dm_db_partition_stats] AS partition_stats
    ON partition_stats.[object_id] = table_info.[object_id]
   AND partition_stats.[index_id] IN (0, 1)
WHERE schema_info.[name] = N'DWD'
  AND table_info.[name] IN (
      N'fact_dispatch_decision_candidate',
      N'fact_robot_incident',
      N'fact_robot_incident_evidence',
      N'fact_robot_operation_event',
      N'robot_event_watermark'
  )
GROUP BY
    schema_info.[name],
    table_info.[name]
ORDER BY table_info.[name];
