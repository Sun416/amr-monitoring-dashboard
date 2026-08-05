USE [IOT2020];
GO

/*
    Purpose:
      Fix future ODS.robot_wifi_history -> DWD.fact_robot_wifi loads.

    Root cause:
      DWD.sp_load_dwd_all_incremental only looked for a source column named
      rssi, while ODS.robot_wifi_history stores the value in
      wifi_signal_level. New DWD rows therefore received NULL rssi values.

    Scope:
      - Alters only the stored-procedure definition.
      - Does not update ODS, DWD, or DWS business data.
      - The project source file 02_create_dwd_load_procedure.sql contains the
        same corrected candidate mapping.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P') IS NULL
BEGIN
    RAISERROR(N'Missing procedure: DWD.sp_load_dwd_all_incremental.', 16, 1);
    RETURN;
END;

IF OBJECT_ID(N'[ODS].[robot_wifi_history]', N'U') IS NULL
BEGIN
    RAISERROR(N'Missing source table: ODS.robot_wifi_history.', 16, 1);
    RETURN;
END;

IF COL_LENGTH(N'ODS.robot_wifi_history', N'wifi_signal_level') IS NULL
BEGIN
    RAISERROR(N'Missing source column: ODS.robot_wifi_history.wifi_signal_level.', 16, 1);
    RETURN;
END;

DECLARE
    @procedure_definition NVARCHAR(MAX),
    @old_fragment NVARCHAR(4000) =
        N'(N''rssi'', N''decimal18'', N''rssi'', 10),',
    @new_candidate NVARCHAR(4000) =
        N'(N''rssi'', N''decimal18'', N''wifi_signal_level'', 20),',
    @replacement_fragment NVARCHAR(4000),
    @old_occurrence_count INT,
    @error_message NVARCHAR(4000);

SELECT
    @procedure_definition = sm.[definition]
FROM sys.sql_modules AS sm
WHERE sm.[object_id] = OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P');

IF @procedure_definition IS NULL
BEGIN
    RAISERROR(N'Unable to read the definition of DWD.sp_load_dwd_all_incremental.', 16, 1);
    RETURN;
END;

/* Pre-execution preview. */
SELECT
    CASE
        WHEN CHARINDEX(@new_candidate, @procedure_definition) > 0 THEN 1
        ELSE 0
    END AS [wifi_signal_level_candidate_is_installed],
    CASE
        WHEN CHARINDEX(@old_fragment, @procedure_definition) > 0 THEN 1
        ELSE 0
    END AS [original_rssi_candidate_exists],
    CASE
        WHEN COL_LENGTH(N'ODS.robot_wifi_history', N'wifi_signal_level') IS NOT NULL THEN 1
        ELSE 0
    END AS [source_column_exists];

IF CHARINDEX(@new_candidate, @procedure_definition) > 0
BEGIN
    SELECT
        N'NO_CHANGE' AS [install_status],
        N'The wifi_signal_level candidate is already installed.' AS [install_message];
    RETURN;
END;

SET @old_occurrence_count =
    (
        LEN(@procedure_definition)
        - LEN(REPLACE(@procedure_definition, @old_fragment, N''))
    ) / NULLIF(LEN(@old_fragment), 0);

IF ISNULL(@old_occurrence_count, 0) <> 1
BEGIN
    RAISERROR(
        N'Expected exactly one original rssi mapping fragment, but found %d. Reinstall the procedure from the corrected 02_create_dwd_load_procedure.sql instead.',
        16,
        1,
        @old_occurrence_count
    );
    RETURN;
END;

SET @replacement_fragment =
    @old_fragment
    + CHAR(13) + CHAR(10)
    + N'            '
    + @new_candidate;

BEGIN TRY
    BEGIN TRANSACTION;

    SET @procedure_definition =
        REPLACE(
            @procedure_definition,
            @old_fragment,
            @replacement_fragment
        );

    /*
        OBJECT_DEFINITION commonly returns a CREATE PROCEDURE header even when
        the module was originally installed with CREATE OR ALTER. Convert only
        that leading keyword so the existing procedure is altered in place.
    */
    SET @procedure_definition = LTRIM(@procedure_definition);

    IF UPPER(LEFT(@procedure_definition, 15)) <> N'CREATE OR ALTER'
       AND UPPER(LEFT(@procedure_definition, 6)) = N'CREATE'
    BEGIN
        SET @procedure_definition =
            STUFF(@procedure_definition, 1, 6, N'ALTER');
    END;

    IF UPPER(LEFT(@procedure_definition, 5)) <> N'ALTER'
       AND UPPER(LEFT(@procedure_definition, 15)) <> N'CREATE OR ALTER'
    BEGIN
        RAISERROR(N'Unexpected stored-procedure definition header; no change was applied.', 16, 1);
    END;

    EXEC sys.sp_executesql @procedure_definition;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.sql_modules AS sm
        WHERE sm.[object_id] = OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P')
          AND CHARINDEX(@new_candidate, sm.[definition]) > 0
    )
    BEGIN
        RAISERROR(N'The procedure changed, but post-install validation did not find the new mapping.', 16, 1);
    END;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    SET @error_message = ERROR_MESSAGE();

    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    RAISERROR(N'Failed to install the future RSSI mapping: %s', 16, 1, @error_message);
    RETURN;
END CATCH;

/* Post-install validation. Expected result: 1. */
SELECT
    CASE
        WHEN CHARINDEX(
            @new_candidate,
            OBJECT_DEFINITION(OBJECT_ID(N'[DWD].[sp_load_dwd_all_incremental]', N'P'))
        ) > 0 THEN 1
        ELSE 0
    END AS [wifi_signal_level_candidate_is_installed];
GO
