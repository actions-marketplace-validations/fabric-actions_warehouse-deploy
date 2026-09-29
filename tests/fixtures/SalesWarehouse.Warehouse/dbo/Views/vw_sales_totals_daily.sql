-- CREATE VIEW in a comment must never be rewritten
CREATE VIEW [dbo].[vw_sales_totals_daily]
AS
SELECT o.OrderDate, SUM(o.Amount) AS Amount
FROM [sales].[Orders] AS o
GROUP BY o.OrderDate;
