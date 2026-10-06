CREATE OR REPLACE TABLE dbo.Machines USING DELTA AS
SELECT * FROM VALUES
  ('M01', 'Press One', 'North'),
  ('M02', 'Press Two', 'North'),
  ('M03', 'Pump Three', 'South'),
  ('M04', 'Pump Four', 'South'),
  ('M05', 'Motor Five', 'North')
AS fixture(MachineId, Name, Site);

CREATE OR REPLACE TABLE dbo.Anomalies USING DELTA AS
SELECT AnomalyId, MachineId, Severity, Status, CAST(DowntimeMinutes AS DOUBLE) AS DowntimeMinutes
FROM VALUES
  ('A01', 'M01', 'critical', 'open', 10),
  ('A02', 'M01', 'critical', 'open', 15),
  ('A03', 'M02', 'critical', 'closed', 100),
  ('A04', 'M03', 'critical', 'open', 30),
  ('A05', 'M04', 'warning', 'open', 5),
  ('A06', 'M03', 'warning', 'closed', 7)
AS fixture(AnomalyId, MachineId, Severity, Status, DowntimeMinutes);

SELECT assert_true(COUNT(*) = 5, 'Expected five machines') FROM dbo.Machines;
SELECT assert_true(COUNT(*) = 6, 'Expected six anomalies') FROM dbo.Anomalies;
SELECT assert_true(COUNT(*) = 3 AND SUM(DowntimeMinutes) = 55, 'Actionable anomaly oracle mismatch')
FROM dbo.Anomalies WHERE Severity = 'critical' AND Status = 'open';
SELECT assert_true(COUNT(DISTINCT MachineId) = 2, 'Expected two affected machines')
FROM dbo.Anomalies WHERE Severity = 'critical' AND Status = 'open';
SELECT assert_true(COUNT(*) = 1 AND MIN(MachineId) = 'M05', 'Expected M05 without anomalies')
FROM dbo.Machines WHERE MachineId NOT IN (SELECT MachineId FROM dbo.Anomalies);