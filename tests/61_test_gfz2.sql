SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT TOP (0) * INTO #Results FROM dbo.ResultsTemplate;
DECLARE @targets int = NULL, @status varchar(10) = NULL, @status_message nvarchar(1000) = NULL;
INSERT #Results
EXEC master.dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorCollationTest',
    @Tables = N'dbo.CollationHeap',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N',
    @MinPages = 1,
    @MinForwardedPct = 0,
    @TargetsFound = @targets OUTPUT,
    @Status = @status OUTPUT,
    @StatusMessage = @status_message OUTPUT;

IF @status = N'SUCCESS'
   AND @targets = 1
   AND EXISTS
       (SELECT 1 FROM #Results AS r
        JOIN dbo.ExpectedVersion AS e ON e.version = r.version
        WHERE r.database_name = N'HeapDoctorCollationTest'
          AND r.schema_name = N'dbo'
          AND r.table_name = N'CollationHeap')
    RAISERROR(N'PASS 61A: collation-mismatched database returned the version-matched heap.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @report nvarchar(1200) = N'FAIL 61A: targets='
        + COALESCE(CONVERT(nvarchar(12), @targets), N'NULL') + N' status='
        + COALESCE(@status, N'NULL') + N' message='
        + COALESCE(@status_message, N'none') + N'.';
    RAISERROR(N'%s', 10, 1, @report) WITH NOWAIT;
END;
GO
