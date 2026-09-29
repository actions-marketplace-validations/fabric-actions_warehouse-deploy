CREATE FUNCTION [dbo].[fn_tax] (@amount DECIMAL(18,2))
RETURNS TABLE
AS
RETURN (SELECT @amount * 0.2 AS Tax);
