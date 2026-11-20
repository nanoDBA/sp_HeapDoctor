/* #225: database-stop dispositions are materialized and counted. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';
IF EXISTS (SELECT 1 FROM #Results AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version
           WHERE r.table_name = N'HeapA')
    RAISERROR(N'PASS 56A: plan result capture uses the expected procedure version.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 56A: the plan result was not captured with the expected version.', 10, 1) WITH NOWAIT;
GO

DECLARE @procedure_text nvarchar(max);
SELECT @procedure_text = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS so ON so.object_id = sm.object_id
WHERE so.object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'#225: materialize unattempted database-stop targets', @procedure_text) > 0
   AND CHARINDEX(N'SKIPPED: DATABASE_STOP_REMAINDER', @procedure_text) > 0
   AND CHARINDEX(N'@skipped_cnt += @database_stop_remaining', @procedure_text) > 0
   AND CHARINDEX(N'HEAP_TARGET_EVENT', @procedure_text) > 0
    RAISERROR(N'PASS 56B: remaining database-stop targets receive counted terminal dispositions.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 56B: remaining database-stop targets are not recorded and counted.', 10, 1) WITH NOWAIT;
GO
