/* #227: preserve forced-plan warning state through resume. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;

ALTER DATABASE HeapDoctorTest SET QUERY_STORE (QUERY_CAPTURE_MODE=NONE);
IF OBJECT_ID(N'dbo.ReproFp',N'U') IS NOT NULL DROP TABLE dbo.ReproFp;
IF OBJECT_ID(N'dbo.Repro_Fp2',N'U') IS NOT NULL DROP TABLE dbo.Repro_Fp2;
IF OBJECT_ID(N'dbo.ReproXFp2',N'U') IS NOT NULL DROP TABLE dbo.ReproXFp2;
SELECT TOP (20000) n=ROW_NUMBER() OVER(ORDER BY (SELECT NULL)) INTO #N
FROM sys.all_columns a CROSS JOIN sys.all_columns b;

CREATE TABLE dbo.ReproFp(id int NOT NULL,pad varchar(4000) NOT NULL);
INSERT dbo.ReproFp(id,pad) SELECT TOP(6000) n,'x' FROM #N;
CREATE UNIQUE NONCLUSTERED INDEX UQ_ReproFp ON dbo.ReproFp(id);
UPDATE dbo.ReproFp SET pad=REPLICATE('x',1500) WHERE id%2=0;

CREATE TABLE dbo.Repro_Fp2(id int NOT NULL,pad varchar(4000) NOT NULL);
INSERT dbo.Repro_Fp2(id,pad) SELECT TOP(6000) n,'x' FROM #N;
CREATE UNIQUE NONCLUSTERED INDEX UQ_Repro_Fp2 ON dbo.Repro_Fp2(id);
UPDATE dbo.Repro_Fp2 SET pad=REPLICATE('x',1500) WHERE id%2=0;

CREATE TABLE dbo.ReproXFp2(id int NOT NULL,pad varchar(4000) NOT NULL);
INSERT dbo.ReproXFp2(id,pad) SELECT TOP(6000) n,'x' FROM #N;
UPDATE dbo.ReproXFp2 SET pad=REPLICATE('x',1500) WHERE id%2=0;
ALTER DATABASE HeapDoctorTest SET QUERY_STORE CLEAR;
ALTER DATABASE HeapDoctorTest SET QUERY_STORE (QUERY_CAPTURE_MODE=ALL);
GO
DECLARE @i int=0,@x bigint;
WHILE @i<25
BEGIN
    SELECT @x=COUNT_BIG(*) FROM dbo.ReproFp WHERE pad LIKE '%q%' OPTION(MAXDOP 1);
    SELECT @x=COUNT_BIG(*) FROM dbo.ReproXFp2 WHERE pad LIKE '%q%' OPTION(MAXDOP 1);
    SET @i+=1;
END;
EXEC sys.sp_query_store_flush_db;
GO
DECLARE @q bigint,@p bigint,@forced int=0;
DECLARE force_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id,p.plan_id
    FROM sys.query_store_plan p
    JOIN sys.query_store_query q ON q.query_id=p.query_id
    JOIN sys.query_store_query_text qt ON qt.query_text_id=q.query_text_id
    WHERE (qt.query_sql_text LIKE N'%FROM dbo.ReproFp WHERE%'
        OR qt.query_sql_text LIKE N'%FROM dbo.ReproXFp2 WHERE%')
      AND qt.query_sql_text NOT LIKE N'%query_store%';
OPEN force_cursor;
FETCH NEXT FROM force_cursor INTO @q,@p;
WHILE @@FETCH_STATUS=0
BEGIN
    EXEC sys.sp_query_store_force_plan @query_id=@q,@plan_id=@p;
    SET @forced+=1;
    FETCH NEXT FROM force_cursor INTO @q,@p;
END;
CLOSE force_cursor;
DEALLOCATE force_cursor;
IF @forced>=2
    RAISERROR(N'PASS 54A setup: forced-plan positive controls are present.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 54A setup: expected forced plans for ReproFp and ReproXFp2; found %d.',10,1,@forced) WITH NOWAIT;
GO
ALTER TABLE dbo.ReproFp SET (LOCK_ESCALATION = AUTO);

SELECT TOP (0) * INTO #Plan FROM dbo.ResultsTemplate;
INSERT INTO #Plan
EXEC dbo.sp_HeapDoctor @Databases=N'HeapDoctorTest',
    @Tables=N'dbo.ReproFp, dbo.Repro_Fp2, dbo.ReproXFp2',
    @CpuSource='QUERY_STORE',@PlanOnly=1,@LogToTable=N'Y',
    @MinPages=10,@MinForwardedPct=0,@AllowCiSwap=1,@PreferCiSwap=1,@PlanCountWarnThreshold=1000;
IF EXISTS (SELECT 1 FROM #Plan r JOIN dbo.ExpectedVersion e ON e.version=r.version WHERE r.table_name=N'ReproFp')
    RAISERROR(N'PASS 54B version: initial plan result matches dbo.ExpectedVersion.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 54B version: initial plan result did not match dbo.ExpectedVersion.',10,1) WITH NOWAIT;

DECLARE @plan_warning varchar(16)=(SELECT TOP (1) warning_severity FROM #Plan WHERE table_name=N'ReproFp'),
    @run uniqueidentifier=(SELECT TOP (1) ExtendedInfo.value(N'(/ScanSummary/RunID)[1]',N'uniqueidentifier')
    FROM dbo.CommandLog WHERE CommandType=N'HEAP_SCAN_SUMMARY' ORDER BY ID DESC),
    @has_forced int=0;
SELECT @has_forced=ExtendedInfo.exist(N'/ScanSummary/Targets/Target[@HasForcedPlans="1"]')
FROM dbo.CommandLog WHERE CommandType=N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.value(N'(/ScanSummary/RunID)[1]',N'uniqueidentifier')=@run;

SELECT TOP (0) * INTO #Resume FROM dbo.ResultsTemplate;
INSERT INTO #Resume
EXEC dbo.sp_HeapDoctor @ResumeRunID=@run,@PlanOnly=1,@LogToTable=N'Y',
    @AllowCiSwap=1,@PreferCiSwap=1,@PlanCountWarnThreshold=1000;
DECLARE @resume_warning varchar(16)=(SELECT TOP (1) warning_severity FROM #Resume WHERE table_name=N'ReproFp'),
        @unsafe_resume bit=CASE WHEN EXISTS(SELECT 1 FROM #Resume WHERE table_name=N'ReproFp' AND action_chosen=N'CI_SWAP_ONLINE') THEN 1 ELSE 0 END;
IF @has_forced=1 AND @plan_warning IS NOT NULL AND @plan_warning<>N'NONE' AND @resume_warning=@plan_warning AND @unsafe_resume=0
    RAISERROR(N'PASS 54C: forced-plan state survived scan summary and resume.',10,1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @report nvarchar(300)=N'FAIL 54C: HasForcedPlans_in_summary='+CONVERT(nvarchar(10),@has_forced)
        +N' plan_warning='+COALESCE(@plan_warning,N'NULL')+N' resumed_warning='+COALESCE(@resume_warning,N'NULL')
        +N' resumed_ReproFp_CI_SWAP='+CONVERT(nvarchar(10),@unsafe_resume)+N'.';
    RAISERROR(N'%s',10,1,@report) WITH NOWAIT;
END

/* Remove forced-plan state and fixtures so later tests start clean. */
DECLARE @q bigint, @p bigint;
DECLARE cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT p.query_id, p.plan_id
    FROM sys.query_store_plan AS p
    JOIN sys.query_store_query AS q ON q.query_id = p.query_id
    JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
    WHERE qt.query_sql_text LIKE N'%FROM dbo.ReproFp WHERE%'
       OR qt.query_sql_text LIKE N'%FROM dbo.ReproXFp2 WHERE%';
OPEN cleanup_cursor;
FETCH NEXT FROM cleanup_cursor INTO @q, @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sys.sp_query_store_unforce_plan @query_id = @q, @plan_id = @p;
    FETCH NEXT FROM cleanup_cursor INTO @q, @p;
END;
CLOSE cleanup_cursor;
DEALLOCATE cleanup_cursor;
DROP TABLE dbo.ReproFp;
DROP TABLE dbo.Repro_Fp2;
DROP TABLE dbo.ReproXFp2;
DELETE FROM dbo.CommandLog WHERE CommandType = N'HEAP_SCAN_SUMMARY';
GO

