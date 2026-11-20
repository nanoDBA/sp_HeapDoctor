/* #235: low-priority schema-lock options are validated and generated for online rebuilds. */
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
    RAISERROR(N'PASS 70A: result capture uses the expected procedure version.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 70A: result capture did not use the expected procedure version.', 10, 1) WITH NOWAIT;
GO

DECLARE @procedure_text nvarchar(max);
SELECT @procedure_text = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS so ON so.object_id = sm.object_id
WHERE so.object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'Both @WaitAtLowPriorityMaxDuration and @WaitAtLowPriorityAbortAfterWait must be supplied together.', @procedure_text) > 0
   AND CHARINDEX(N'between 1 and 10080 minutes', @procedure_text) > 0
   AND CHARINDEX(N'must be NONE, SELF, or BLOCKERS', @procedure_text) > 0
    RAISERROR(N'PASS 70B: the option pair, duration, and abort action are validated.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 70B: low-priority input validation is missing.', 10, 1) WITH NOWAIT;

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'WAIT_AT_LOW_PRIORITY', @procedure_text) > 0
   AND CHARINDEX(N'/*WAIT_AT_LOW_PRIORITY_ALTER*/', @procedure_text) > 0
   AND CHARINDEX(N'/*WAIT_AT_LOW_PRIORITY_CREATE*/', @procedure_text) > 0
   AND CHARINDEX(N'>= 16', @procedure_text) > 0
   AND CHARINDEX(N'@WaitAtLowPriorityMaxDuration = ', @procedure_text) > 0
    RAISERROR(N'PASS 70C: online rebuild and supported CI-swap builders log the low-priority options.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 70C: online DDL or logged low-priority option generation is missing.', 10, 1) WITH NOWAIT;
GO
