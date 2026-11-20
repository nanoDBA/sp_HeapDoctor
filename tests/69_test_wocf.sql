/* #230: QuickieStore documentation matches the public parameter and column names. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT * INTO #T FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #T
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapA',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'N';
IF EXISTS (SELECT 1 FROM #T AS t JOIN dbo.ExpectedVersion AS e ON e.version = t.version WHERE t.table_name = N'HeapA')
    RAISERROR(N'PASS 69A: result capture uses the expected procedure version.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 69A: result capture did not use the expected procedure version.', 10, 1) WITH NOWAIT;
GO

DECLARE @procedure_text nvarchar(max);
SELECT @procedure_text = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS so ON so.object_id = sm.object_id
WHERE so.object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'current public sp_QuickieStore is not supported by this adapter', @procedure_text) > 0
   AND CHARINDEX(N'@sort_order', @procedure_text) > 0
   AND CHARINDEX(N'@format_output = 0', @procedure_text) > 0
   AND CHARINDEX(N'total_cpu_time_ms', @procedure_text) > 0
   AND CHARINDEX(N'error 11528', @procedure_text) > 0
    RAISERROR(N'PASS 69B: help names the real QuickieStore contract and its adapter limitation.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 69B: QuickieStore help is missing accurate contract or limitation details.', 10, 1) WITH NOWAIT;
GO
