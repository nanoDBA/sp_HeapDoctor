SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;

IF OBJECT_ID(N'dbo.P2_WideKey', N'U') IS NOT NULL DROP TABLE dbo.P2_WideKey;
IF OBJECT_ID(N'dbo.P2_NullableKey', N'U') IS NOT NULL DROP TABLE dbo.P2_NullableKey;
CREATE TABLE dbo.P2_WideKey
(
    ID int NOT NULL,
    KeyCol char(1000) NOT NULL,
    Padding varchar(4000) NOT NULL
);
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
INSERT dbo.P2_WideKey (ID, KeyCol, Padding)
SELECT TOP (10000) n,
       CONVERT(char(1000), RIGHT('00000' + CONVERT(varchar(5), n), 5)),
       REPLICATE('A', 10)
FROM N;
UPDATE dbo.P2_WideKey SET Padding = REPLICATE('X', 3000) WHERE ID <= 5000;
CREATE UNIQUE NONCLUSTERED INDEX UX_P2_WideKey ON dbo.P2_WideKey(KeyCol);
CREATE TABLE dbo.P2_NullableKey
(
    ID int NOT NULL,
    NullableKey int NULL,
    Padding varchar(2000) NOT NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_P2_NullableKey ON dbo.P2_NullableKey(ID, NullableKey);
;WITH N AS
(
    SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
INSERT dbo.P2_NullableKey (ID, NullableKey, Padding)
SELECT TOP (6000) n, NULL, 'x' FROM N;
UPDATE dbo.P2_NullableKey SET Padding = REPLICATE('X', 1500) WHERE ID % 2 = 0;
GO

SELECT TOP (0) * INTO #Plan FROM dbo.ResultsTemplate;
INSERT #Plan
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @Tables = N'dbo.P2_WideKey, dbo.P2_NullableKey',
    @CpuSource = 'NONE', @PlanOnly = 1, @LogToTable = N'N',
    @MinPages = 10, @MinForwardedPct = 0, @AllowCiSwap = 1, @PreferCiSwap = 1;

DECLARE @versioned_plan_rows int =
    (SELECT COUNT(*) FROM #Plan AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version
     WHERE r.table_name IN (N'P2_WideKey', N'P2_NullableKey'));
DECLARE @unsafe_plan bit =
    CASE WHEN EXISTS (SELECT 1 FROM #Plan
                      WHERE table_name IN (N'P2_WideKey', N'P2_NullableKey')
                        AND action_chosen = N'CI_SWAP_ONLINE')
         THEN 1 ELSE 0 END;

DELETE FROM dbo.CommandLog WHERE ObjectName = N'P2_WideKey';
DECLARE @return_code int = NULL, @targets int = NULL, @succeeded int = NULL, @failed int = NULL;
BEGIN TRY
    EXEC @return_code = dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest', @Tables = N'dbo.P2_WideKey',
        @CpuSource = 'NONE', @PlanOnly = 0, @LogToTable = N'Y',
        @MinPages = 10, @MinForwardedPct = 0, @AllowCiSwap = 1, @PreferCiSwap = 1,
        @TargetsFound = @targets OUTPUT, @Succeeded = @succeeded OUTPUT, @Failed = @failed OUTPUT;
END TRY
BEGIN CATCH
    RAISERROR(N'63A execution raised an unexpected SQL error.', 10, 1) WITH NOWAIT;
END CATCH;

DECLARE @error_1944_rows int =
    (SELECT COUNT(*) FROM dbo.CommandLog
     WHERE ObjectName = N'P2_WideKey'
       AND (ErrorNumber = 1944 OR ErrorMessage LIKE N'%cannot exceed 900 bytes%'));

IF @versioned_plan_rows = 2
   AND @unsafe_plan = 0
   AND @error_1944_rows = 0
   AND ISNULL(@failed, 0) = 0
    RAISERROR(N'PASS 63A: unsupported key candidates are excluded from CI swap.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @report nvarchar(300) = N'FAIL 63A: versioned_plan_rows='
        + CONVERT(nvarchar(10), @versioned_plan_rows) + N' unsafe_plan='
        + CONVERT(nvarchar(10), @unsafe_plan) + N' error_1944_rows='
        + CONVERT(nvarchar(10), @error_1944_rows) + N' failed='
        + COALESCE(CONVERT(nvarchar(10), @failed), N'NULL') + N'.';
    RAISERROR(N'%s', 10, 1, @report) WITH NOWAIT;
END;

DELETE FROM dbo.CommandLog WHERE ObjectName = N'P2_WideKey';
DROP TABLE dbo.P2_WideKey;
DROP TABLE dbo.P2_NullableKey;
GO
