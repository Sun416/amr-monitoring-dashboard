USE IOT2020;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/*
    调整 ODS 自动增量控制表的分层加载策略。

    本脚本只修改 [ODS].[etl_watermark] 控制表，不会导入、不删除、不改动 ODS 业务表数据。

    调整原则：
    1. AMR_Rawdata、AMR_Queue、AMR_Subjob_Analyze、amr_hourly_summary 等事实/流水表继续按 ID 或时间增量。
    2. MA_AMR 与 MA_AMR_* 这类主数据、配置、地图、工厂、产线、站点、任务类型等表，改为 FULL_REPLACE。
    3. AMR_List、AMR_ESP_Button_Configuration 属于清单/配置类，也改为 FULL_REPLACE。
    4. AMR_Currentdata、AMR_Robot_Mode 保持 SNAPSHOT。
    5. old、backup、test 表继续 IGNORE，并关闭 is_enabled。
*/

BEGIN TRY
    BEGIN TRAN;

    /* 主数据 / 配置 / 地图 / 参考类表：每次全量覆盖 ODS，避免被误当成业务流水增量表。 */
    UPDATE [ODS].[etl_watermark]
    SET
        load_mode = N'FULL_REPLACE',
        watermark_column = NULL,
        last_bigint_value = NULL,
        last_datetime_value = NULL,
        last_load_time = NULL,
        is_enabled = 1
    WHERE target_schema = N'ODS'
      AND source_schema = N'dbo'
      AND (
             source_table = N'MA_AMR'
          OR source_table LIKE N'MA[_]AMR[_]%'
          OR source_table IN (
                N'AMR_List',
                N'AMR_ESP_Button_Configuration'
             )
      );

    /* 当前状态类表：保留快照模式。 */
    UPDATE [ODS].[etl_watermark]
    SET
        load_mode = N'SNAPSHOT',
        watermark_column = NULL,
        last_bigint_value = NULL,
        last_datetime_value = NULL,
        last_load_time = NULL,
        is_enabled = 1
    WHERE target_schema = N'ODS'
      AND source_schema = N'dbo'
      AND source_table IN (
            N'AMR_Currentdata',
            N'AMR_Robot_Mode'
      );

    /* 历史旧表、测试表、备份表：不进入自动增量任务。 */
    UPDATE [ODS].[etl_watermark]
    SET
        load_mode = N'IGNORE',
        watermark_column = NULL,
        last_bigint_value = NULL,
        last_datetime_value = NULL,
        last_load_time = NULL,
        is_enabled = 0
    WHERE target_schema = N'ODS'
      AND source_schema = N'dbo'
      AND (
             LOWER(source_table) LIKE N'%old%'
          OR LOWER(source_table) LIKE N'%backup%'
          OR LOWER(source_table) LIKE N'%test%'
      );

    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK;

    THROW;
END CATCH;
GO

/* 检查 1：看每种加载模式现在有多少张表。 */
SELECT
    load_mode,
    is_enabled,
    COUNT(*) AS table_count
FROM [ODS].[etl_watermark]
GROUP BY
    load_mode,
    is_enabled
ORDER BY
    load_mode,
    is_enabled;

/* 检查 2：重点看这次被调整的表。 */
SELECT
    source_table,
    load_mode,
    watermark_column,
    last_bigint_value,
    last_datetime_value,
    last_load_time,
    is_enabled
FROM [ODS].[etl_watermark]
WHERE target_schema = N'ODS'
  AND source_schema = N'dbo'
  AND (
         source_table = N'MA_AMR'
      OR source_table LIKE N'MA[_]AMR[_]%'
      OR source_table IN (
            N'AMR_List',
            N'AMR_ESP_Button_Configuration',
            N'AMR_Currentdata',
            N'AMR_Robot_Mode'
         )
      OR LOWER(source_table) LIKE N'%old%'
      OR LOWER(source_table) LIKE N'%backup%'
      OR LOWER(source_table) LIKE N'%test%'
  )
ORDER BY
    source_table;
GO

-- END OF SCRIPT.
