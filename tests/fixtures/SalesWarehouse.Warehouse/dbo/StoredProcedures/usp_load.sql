CREATE PROCEDURE [dbo].[usp_load]
AS
BEGIN
    CREATE TABLE #stage (Id INT NULL);
    SELECT COUNT(*) FROM #stage;
END
