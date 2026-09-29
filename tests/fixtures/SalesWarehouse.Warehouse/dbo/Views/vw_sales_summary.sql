CREATE VIEW [dbo].[vw_sales_summary]
AS
SELECT SUM(d.Amount) AS Total, 'CREATE VIEW inside a string' AS Note
FROM [dbo].[vw_sales_totals_daily] AS d;
