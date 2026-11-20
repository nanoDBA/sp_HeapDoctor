/* #231: Query Store attribution includes RID Lookup and matches database names. */
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
    RAISERROR(N'PASS 68A: result capture uses the expected procedure version.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 68A: result capture did not use the expected procedure version.', 10, 1) WITH NOWAIT;
GO

DECLARE @procedure_text nvarchar(max);
SELECT @procedure_text = sm.definition
FROM master.sys.sql_modules AS sm
JOIN master.sys.objects AS so ON so.object_id = sm.object_id
WHERE so.object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'@PhysicalOp="RID Lookup"', @procedure_text) > 0
   AND CHARINDEX(N'@Database', @procedure_text) > 0
   AND CHARINDEX(N'pm.database_name COLLATE DATABASE_DEFAULT = DB_NAME() COLLATE DATABASE_DEFAULT', @procedure_text) > 0
    RAISERROR(N'PASS 68B: RID Lookup objects are mapped with their database identity.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 68B: RID Lookup or database identity is missing from Query Store mapping.', 10, 1) WITH NOWAIT;

IF @procedure_text IS NOT NULL
   AND CHARINDEX(N'whole-plan CPU', @procedure_text) > 0
    RAISERROR(N'PASS 68C: the Query Store output documents whole-plan CPU attribution.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 68C: whole-plan CPU attribution is not documented.', 10, 1) WITH NOWAIT;
GO
