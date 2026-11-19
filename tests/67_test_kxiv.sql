/* #220: claim queue rows atomically and keep workers alive while work is locked. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;

DECLARE @definition nvarchar(max);
SELECT @definition = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS o ON o.object_id = sm.object_id
JOIN master.sys.schemas AS s ON s.schema_id = o.schema_id
WHERE s.name = N'dbo' AND o.name = N'sp_HeapDoctor' AND o.type = N'P';
DECLARE @atomic_claim bit = CASE WHEN @definition LIKE N'%UPDATE NextUnclaimed%'
    AND @definition LIKE N'%FROM dbo.QueueHeapRebuild AS qhr WITH (UPDLOCK, ROWLOCK, READPAST)%' THEN 1 ELSE 0 END;
DECLARE @atomic_reclaim bit = CASE WHEN @definition LIKE N'%UPDATE Stranded%'
    AND @definition LIKE N'%FROM dbo.QueueHeapRebuild AS qhr WITH (UPDLOCK, ROWLOCK, READPAST)%' THEN 1 ELSE 0 END;
DECLARE @retry_locked_work bit = CASE WHEN @definition LIKE N'%AND EXISTS%FROM dbo.QueueHeapRebuild AS qhr%WHERE qhr.QueueID = @queue_id AND qhr.TableStartTime IS NULL%WAITFOR DELAY ''00:00:00.100''%'
    THEN 1 ELSE 0 END;

IF @atomic_claim = 1
    RAISERROR(N'PASS 67A: normal queue claims update the UPDLOCK picker row directly.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 67A: normal claims can race between selecting and updating a queue row.', 10, 1) WITH NOWAIT;

IF @atomic_reclaim = 1
    RAISERROR(N'PASS 67B: stranded-row recovery updates its UPDLOCK picker row directly.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 67B: stranded-row recovery can race between selecting and updating a row.', 10, 1) WITH NOWAIT;

IF @retry_locked_work = 1
    RAISERROR(N'PASS 67C: workers retry when unclaimed work exists but is temporarily locked.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 67C: a zero-row claim can exit while unclaimed work remains.', 10, 1) WITH NOWAIT;

SELECT TOP (0) * INTO #Plan FROM dbo.ResultsTemplate;
INSERT #Plan
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @Tables = N'dbo.HeapA',
    @CpuSource = 'NONE', @PlanOnly = 1, @LogToTable = N'N',
    @MinPages = 10, @MinForwardedPct = 0;

IF EXISTS (SELECT 1 FROM #Plan AS r JOIN dbo.ExpectedVersion AS e ON e.version = r.version)
    RAISERROR(N'PASS 67D: the procedure result contract still matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 67D: procedure result version did not match dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
