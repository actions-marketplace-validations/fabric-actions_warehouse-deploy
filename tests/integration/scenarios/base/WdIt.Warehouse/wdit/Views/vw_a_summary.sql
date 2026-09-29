CREATE VIEW [wdit].[vw_a_summary]
AS
SELECT SUM([Amount]) AS [Total]
FROM [wdit].[vw_b_monthly];
