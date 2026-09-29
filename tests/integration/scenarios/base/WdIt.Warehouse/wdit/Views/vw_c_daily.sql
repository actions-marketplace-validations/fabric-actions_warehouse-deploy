CREATE VIEW [wdit].[vw_c_daily]
AS
SELECT [SaleDate], SUM([Amount]) AS [Amount]
FROM [wdit].[Sales]
GROUP BY [SaleDate];
