/* #238: queue table initialization is serialized across parallel starters. */
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
    RAISERROR(N'PASS 64A: plan result capture uses the expected procedure version.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 64A: the plan result was not captured with the expected version.', 10, 1) WITH NOWAIT;
GO

DECLARE @procedure_text nvarchar(max);
DECLARE @lock_position integer, @create_position integer, @release_position integer,
        @catch_position integer, @catch_release_position integer;
SELECT @procedure_text = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS so ON so.object_id = sm.object_id
WHERE so.object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');
SET @lock_position = CHARINDEX(N'@Resource = N''sp_HeapDoctor_QueueHeapRebuild_DDL''', @procedure_text);
SET @create_position = CHARINDEX(N'CREATE TABLE dbo.QueueHeapRebuild', @procedure_text, @lock_position);
SET @release_position = CHARINDEX(N'sys.sp_releaseapplock', @procedure_text, @create_position);
SET @catch_position = CHARINDEX(N'BEGIN CATCH', @procedure_text, @release_position);
SET @catch_release_position = CHARINDEX(N'sys.sp_releaseapplock', @procedure_text, @catch_position);

IF @procedure_text IS NOT NULL
   AND @lock_position > 0 AND @create_position > @lock_position
   AND @release_position > @create_position AND @catch_release_position > @catch_position
   AND CHARINDEX(N'@LockOwner = N''Session''', @procedure_text) > 0
    RAISERROR(N'PASS 64B: queue creation runs under a released session application lock.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 64B: queue creation has no session application lock.', 10, 1) WITH NOWAIT;
GO
