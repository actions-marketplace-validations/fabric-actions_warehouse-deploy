-- Resets ONLY the integration-test schema [wdit] in the DEV warehouse.
-- Never point the integration workflow at a warehouse with real data in [wdit].
DROP VIEW IF EXISTS [wdit].[vw_d_broken];
DROP VIEW IF EXISTS [wdit].[vw_a_summary];
DROP VIEW IF EXISTS [wdit].[vw_b_monthly];
DROP VIEW IF EXISTS [wdit].[vw_c_daily];
DROP TABLE IF EXISTS [wdit].[Sales];
DROP TABLE IF EXISTS [wdit].[Customer];
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'wdit') EXEC('DROP SCHEMA [wdit]');
