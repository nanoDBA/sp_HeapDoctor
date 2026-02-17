/*
sp_HeapDoctor Test Harness — Cleanup

Drops the test database.

Run with: sqlcmd -S YourServer -i 99_cleanup.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;

IF DB_ID(N'HeapDoctorTest') IS NOT NULL
BEGIN
    RAISERROR(N'Dropping HeapDoctorTest database...', 10, 1) WITH NOWAIT;
    ALTER DATABASE [HeapDoctorTest] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [HeapDoctorTest];
    RAISERROR(N'Done.', 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    RAISERROR(N'HeapDoctorTest database does not exist. Nothing to clean up.', 10, 1) WITH NOWAIT;
END
GO
