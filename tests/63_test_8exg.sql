SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE HeapDoctorTest;
GO

SELECT TOP (0) * INTO #Results FROM dbo.ResultsTemplate;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases=N'HeapDoctorTest', @Tables=N'dbo.HeapA', @CpuSource='NONE',
    @PlanOnly=1, @LogToTable=N'Y', @ObfuscateKey=N'p2-reveal-key',
    @ObfuscateSeed=N'p2-reveal-seed', @MinPages=0, @MinForwardedPct=0,
    @IncludeHealthyHeaps=1;

DECLARE @run_id uniqueidentifier, @caught_number int=NULL, @caught_message nvarchar(4000)=NULL;
SELECT TOP (1) @run_id=ExtendedInfo.value(N'(/ScanSummary/RunID)[1]',N'uniqueidentifier')
FROM dbo.CommandLog WHERE CommandType=N'HEAP_SCAN_SUMMARY' ORDER BY ID DESC;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @RevealKey=N'wrong-key', @RevealRunID=@run_id;
END TRY
BEGIN CATCH
    SET @caught_number=ERROR_NUMBER();
    SET @caught_message=ERROR_MESSAGE();
END CATCH;
DECLARE @procedure_text nvarchar(max)=(SELECT m.definition FROM master.sys.sql_modules AS m WHERE m.object_id=OBJECT_ID(N'master.dbo.sp_HeapDoctor'));
DECLARE @decrypt_error_at int=CHARINDEX(N'Encrypted mapping chunk decryption failed.',@procedure_text);
DECLARE @decrypt_return_at int=CHARINDEX(N'RETURN;',@procedure_text,@decrypt_error_at);
DECLARE @next_chunk_fetch_at int=CHARINDEX(N'FETCH NEXT FROM mapping_chunks',@procedure_text,@decrypt_error_at);
IF @caught_number=50000 AND @caught_message LIKE N'%Encrypted mapping chunk decryption failed%'
   AND @decrypt_error_at>0 AND @decrypt_return_at>@decrypt_error_at
   AND (@next_chunk_fetch_at=0 OR @decrypt_return_at<@next_chunk_fetch_at)
    RAISERROR(N'PASS 63A: a wrong reveal key raises one decryption error and exits the chunk loop.',10,1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @fail_63a nvarchar(2000)=N'FAIL 63A: wrong-key reveal returned an unexpected or cursor-follow-up error. number='
        +ISNULL(CONVERT(nvarchar(20),@caught_number),N'NULL')+N' message='+ISNULL(LEFT(@caught_message,300),N'NULL')
        +N' error_at='+CONVERT(nvarchar(20),@decrypt_error_at)+N' return_at='+CONVERT(nvarchar(20),@decrypt_return_at)
        +N' fetch_at='+CONVERT(nvarchar(20),@next_chunk_fetch_at);
    RAISERROR(N'%s',10,1,@fail_63a) WITH NOWAIT;
END

DECLARE @stored_seed nvarchar(128), @legacy_hex nvarchar(max), @legacy_xml nvarchar(max), @passphrase nvarchar(max);
SELECT @stored_seed=ExtendedInfo.value(N'(/ScanSummary/ObfuscateSeed)[1]',N'nvarchar(128)')
FROM dbo.CommandLog WHERE CommandType=N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.value(N'(/ScanSummary/RunID)[1]',N'uniqueidentifier')=@run_id;
SET @passphrase=N'p2-reveal-key'+@stored_seed;
SET @legacy_xml=CONVERT(nvarchar(max),(
    SELECT v.object_type,v.real_name,v.pseudonym
    FROM (VALUES (N'Database',N'HeapDoctorTest',N'DB_01234567'),
                 (N'Schema',N'dbo',N'S_01234567'),
                 (N'Table',N'HeapA',N'T_01234567')) AS v(object_type,real_name,pseudonym)
    FOR XML RAW(N'Object'),ROOT(N'ObfuscatedMapping'),ELEMENTS));
SET @legacy_hex=CONVERT(nvarchar(max),ENCRYPTBYPASSPHRASE(@passphrase,CONVERT(varbinary(max),@legacy_xml)),2);
UPDATE dbo.CommandLog
SET ExtendedInfo.modify(N'replace value of (/ScanSummary/ObfuscatedMappingHex/text())[1] with sql:variable("@legacy_hex")')
WHERE CommandType=N'HEAP_SCAN_SUMMARY'
  AND ExtendedInfo.value(N'(/ScanSummary/RunID)[1]',N'uniqueidentifier')=@run_id;
CREATE TABLE #Mapping(pseudonym nvarchar(100),object_type varchar(10),real_name sysname);
INSERT #Mapping EXEC dbo.sp_HeapDoctor @RevealKey=N'p2-reveal-key',@RevealRunID=@run_id;
IF EXISTS(SELECT 1 FROM #Mapping WHERE object_type='Table' AND real_name=N'HeapA')
    RAISERROR(N'PASS 63B: the legacy single-blob mapping format is revealed.',10,1) WITH NOWAIT;
ELSE
    RAISERROR(N'FAIL 63B: the legacy single-blob mapping format was not revealed.',10,1) WITH NOWAIT;
