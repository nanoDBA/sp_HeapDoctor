/*
sp_HeapDoctor - target disposition events (#187)

sp_HeapDoctor writes one durable event per disposed target to dbo.CommandLog
under CommandType = 'HEAP_TARGET_EVENT'. CommandLog has no target_id column, so
identity lives in ExtendedInfo XML -- but always at the SAME fixed path, in
every event row, so a single shred turns the stream into a relational shape.

This script is NOT run by the procedure and creates nothing automatically.
Run it yourself if you want the view; or lift the SELECT into your own query.

    Outcome codes:  SUCCEEDED | FAILED | SKIPPED | RECOVERY_REQUIRED
    Event codes:    TARGET_DISPOSITION (terminal) | ACTION_CHANGED (non-terminal)

RECOVERY_REQUIRED means a CI swap created the clustered index but failed to drop
it: the table is currently CLUSTERED, not a heap, and needs manual remediation.
The run's aggregate counters record it as a success, which is exactly why this
stream exists.
*/

CREATE OR ALTER VIEW dbo.HeapDoctorTargetEvents
AS
SELECT
    cl.ID                                                                   AS CommandLogID,
    cl.ExtendedInfo.value('(/TargetEvent/RunID)[1]',           'uniqueidentifier') AS RunID,
    cl.ExtendedInfo.value('(/TargetEvent/TargetId)[1]',        'integer')          AS TargetId,
    cl.ExtendedInfo.value('(/TargetEvent/EventTime)[1]',       'datetime2(3)')     AS EventTime,
    cl.ExtendedInfo.value('(/TargetEvent/EventCode)[1]',       'nvarchar(50)')     AS EventCode,
    cl.ExtendedInfo.value('(/TargetEvent/IsTerminalEvent)[1]', 'bit')              AS IsTerminalEvent,
    cl.ExtendedInfo.value('(/TargetEvent/OutcomeCode)[1]',     'nvarchar(30)')     AS OutcomeCode,
    cl.ExtendedInfo.value('(/TargetEvent/MessageText)[1]',     'nvarchar(4000)')   AS MessageText,
    cl.ExtendedInfo.value('(/TargetEvent/SessionId)[1]',       'integer')          AS SessionId,
    cl.ExtendedInfo.value('(/TargetEvent/Version)[1]',         'nvarchar(20)')     AS Version,
    cl.ExtendedInfo.value('(/TargetEvent/Detail/ActionExecuted)[1]',    'varchar(32)')  AS ActionExecuted,
    cl.ExtendedInfo.value('(/TargetEvent/Detail/ActionAtDiscovery)[1]', 'varchar(32)')  AS ActionAtDiscovery,
    cl.ExtendedInfo.value('(/TargetEvent/Detail/RecoveryRequired)[1]',  'bit')          AS RecoveryRequired,
    cl.DatabaseName,
    cl.ObjectName                                                            AS TargetName,
    cl.StartTime,
    cl.EndTime,
    cl.ErrorNumber,
    cl.ErrorMessage
FROM dbo.CommandLog AS cl
WHERE cl.CommandType = N'HEAP_TARGET_EVENT';
GO

/*
Examples
--------

-- Every target's final disposition for one run
SELECT TargetId, TargetName, OutcomeCode, MessageText
FROM dbo.HeapDoctorTargetEvents
WHERE RunID = '<run id>' AND IsTerminalEvent = 1
ORDER BY TargetId;

-- Targets needing manual remediation, which the aggregate counters call successes
SELECT RunID, TargetName, EventTime, MessageText
FROM dbo.HeapDoctorTargetEvents
WHERE OutcomeCode = N'RECOVERY_REQUIRED'
ORDER BY EventTime DESC;

-- Where execution diverged from the plan
SELECT RunID, TargetName, ActionAtDiscovery, ActionExecuted
FROM dbo.HeapDoctorTargetEvents
WHERE EventCode = N'ACTION_CHANGED'
ORDER BY EventTime DESC;

-- Skips, without parsing any message text
SELECT DatabaseName, TargetName, MessageText
FROM dbo.HeapDoctorTargetEvents
WHERE OutcomeCode = N'SKIPPED';
*/
