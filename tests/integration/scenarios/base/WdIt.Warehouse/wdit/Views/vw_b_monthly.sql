CREATE VIEW [wdit].[vw_b_monthly]
AS
SELECT YEAR([SaleDate]) AS [Year], MONTH([SaleDate]) AS [Month], SUM([Amount]) AS [Amount]
FROM [wdit].[vw_c_daily]
GROUP BY YEAR([SaleDate]), MONTH([SaleDate]);
