/*
sp_HeapDoctor Extended Events Session
======================================

Captures rebuild operations, lock escalation, and DDL events for
sp_HeapDoctor monitoring. Replaces the deprecated sp_trace_generateevent
(SQL Trace) with Extended Events for SQL Server 2016+.

Usage:
  1. Run this script to create the session (stopped by default).
  2. Start the session before running sp_HeapDoctor:
       ALTER EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER STATE = START;
  3. Run sp_HeapDoctor as normal.
  4. Query results:
       SELECT * FROM sp_HeapDoctor_Monitor_Data ORDER BY event_time;
  5. Stop the session:
       ALTER EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER STATE = STOP;

Captured events:
  - sql_statement_completed: ALTER TABLE REBUILD and CREATE/DROP CLUSTERED INDEX
  - lock_escalation: Sch-M lock escalation on target tables
  - object_altered: DDL tracking for heap rebuilds and CI swap operations
  - user_event: sp_trace_generateevent calls (event_class 82, backward compat)

Ring buffer target retains the last 2000 events (~50 MB max).
Drop and recreate to reset. No performance impact when stopped.
*/

-- Drop existing session if it exists
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'sp_HeapDoctor_Monitor')
    DROP EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER;
GO

CREATE EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER

-- Capture ALTER TABLE REBUILD and CREATE/DROP CLUSTERED INDEX statements
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.nt_username
    )
    WHERE (
        [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%ALTER TABLE%REBUILD%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%CREATE%CLUSTERED INDEX%CX__Temp__%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%DROP INDEX%CX__Temp__%')
    )
),

-- Capture lock escalation events (Sch-M contention visibility)
ADD EVENT sqlserver.lock_escalation (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name
    )
),

-- Capture DDL events for CI swap operations
ADD EVENT sqlserver.object_altered (
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name
    )
    WHERE (
        [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%sp_HeapDoctor%')
        OR [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%CX__Temp__%')
    )
),

-- Capture user events from sp_trace_generateevent (backward compatibility)
ADD EVENT sqlserver.user_event (
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.username
    )
    WHERE ([user_info] LIKE N'sp_HeapDoctor%')
)

-- Ring buffer target: last 2000 events, 50 MB max
ADD TARGET package0.ring_buffer (
    SET max_events_limit = 2000,
        max_memory = 51200  -- 50 MB in KB
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE = OFF
);
GO

RAISERROR(N'Extended Events session [sp_HeapDoctor_Monitor] created (stopped).', 10, 1) WITH NOWAIT;
RAISERROR(N'Start:  ALTER EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER STATE = START;', 10, 1) WITH NOWAIT;
RAISERROR(N'Stop:   ALTER EVENT SESSION [sp_HeapDoctor_Monitor] ON SERVER STATE = STOP;', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Helper view: parse ring buffer XML into a readable table
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.sp_HeapDoctor_Monitor_Data', N'V') IS NOT NULL
    DROP VIEW dbo.sp_HeapDoctor_Monitor_Data;
GO

CREATE VIEW dbo.sp_HeapDoctor_Monitor_Data
AS
SELECT
    x.event_data.value(N'(@name)', N'nvarchar(100)')                     AS event_name,
    x.event_data.value(N'(@timestamp)', N'datetime2(3)')                 AS event_time,
    x.event_data.value(N'(data[@name="duration"]/value)[1]', N'bigint')  AS duration_us,
    x.event_data.value(N'(data[@name="cpu_time"]/value)[1]', N'bigint')  AS cpu_time_us,
    x.event_data.value(N'(data[@name="logical_reads"]/value)[1]', N'bigint') AS logical_reads,
    x.event_data.value(N'(data[@name="physical_reads"]/value)[1]', N'bigint') AS physical_reads,
    x.event_data.value(N'(data[@name="writes"]/value)[1]', N'bigint')    AS writes,
    x.event_data.value(N'(data[@name="row_count"]/value)[1]', N'bigint') AS row_count,
    x.event_data.value(N'(data[@name="user_info"]/value)[1]', N'nvarchar(128)') AS user_info,
    x.event_data.value(N'(action[@name="sql_text"]/value)[1]', N'nvarchar(max)') AS sql_text,
    x.event_data.value(N'(action[@name="database_name"]/value)[1]', N'nvarchar(128)') AS database_name,
    x.event_data.value(N'(action[@name="session_id"]/value)[1]', N'int') AS session_id,
    x.event_data.value(N'(action[@name="username"]/value)[1]', N'nvarchar(128)') AS username
FROM (
    SELECT CAST(target_data AS xml) AS target_xml
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
    WHERE s.name = N'sp_HeapDoctor_Monitor'
      AND t.target_name = N'ring_buffer'
) AS rb
CROSS APPLY rb.target_xml.nodes(N'RingBufferTarget/event') AS x(event_data);
GO

RAISERROR(N'View dbo.sp_HeapDoctor_Monitor_Data created. Query: SELECT * FROM sp_HeapDoctor_Monitor_Data ORDER BY event_time;', 10, 1) WITH NOWAIT;
GO
