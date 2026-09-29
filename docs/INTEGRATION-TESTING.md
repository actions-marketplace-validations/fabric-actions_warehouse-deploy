# Integration testing against a DEV Fabric workspace

The unit and orchestration tests use a fake `sqlcmd` and need no Fabric access, so
they run on every push and pull request. The integration workflow
[`.github/workflows/integration.yml`](../.github/workflows/integration.yml) runs the
real action against a real warehouse. It is **manual** (`workflow_dispatch`) and
deliberately separate from the pull-request checks.

## One-time setup

1. **DEV workspace and warehouse.** Create a Fabric workspace for testing only, with an
   empty warehouse, for example `WdIntegration`. Never use a warehouse that holds real
   data.
2. **Service Principal.** Create an app registration and a client secret. In the
   Fabric admin portal, allow service principals to use Fabric APIs. Add the principal
   to the DEV workspace as **Contributor**.
3. **GitHub environment `fabric-dev`** in this repository:

   | Kind | Name | Value |
   |---|---|---|
   | secret | `FABRIC_TENANT_ID` | tenant GUID |
   | secret | `FABRIC_CLIENT_ID` | app (client) GUID |
   | secret | `FABRIC_CLIENT_SECRET` | client secret |
   | secret | `FABRIC_WORKSPACE_ID` | DEV workspace GUID |
   | variable | `IT_WAREHOUSE_NAME` | e.g. `WdIntegration` |
   | variable | `IT_SQL_ENDPOINT` | SQL connection string of the warehouse (Warehouse → Settings → SQL endpoint) |

   You can add required reviewers to the environment so that nobody runs the
   workflow by accident.

## What the workflow does

All test objects live in the dedicated **`[wdit]`** schema.
`tests/integration/reset.sql` drops only the named `[wdit]` objects at the start of
each run, so every run starts from a known state.

Each scenario is built from `tests/integration/scenarios/base/WdIt.Warehouse` plus an
overlay of changed files (`New-Scenario.ps1`). The result goes to `_it/<scenario>/`
inside the workspace. It is git-ignored and never committed.

| # | Scenario | Folder | Expected |
|---|---|---|---|
| 1 | Create new objects | `base` | `SUCCESS`, `tables-created=2`, `views-deployed=3` |
| 2 | Same deployment again | `base` | `SUCCESS`, `tables-created=0`, `columns-added=0` (idempotent) |
| 3 | Add a nullable column | `add-column` (adds `Customer.Email VARCHAR(320) NULL`) | `columns-added=1` via `ALTER TABLE … ADD` |
| 4 | Views in the wrong alphabetical order | `base`: `vw_a_summary → vw_b_monthly → vw_c_daily → Sales` | `view-passes ≥ 2` (checked in scenario 1) |
| 5 | Unresolvable dependency | `broken-dependency` (`vw_d_broken` reads a missing view) | step fails, `failure-category=VIEW_DEPLOYMENT_FAILED`, real SQL error in the log |
| 6 | Add a NOT NULL column | `not-null` (adds `Customer.CustomerType … NOT NULL`) | step fails, `failure-category=UNSAFE_SCHEMA_CHANGE`, no table DDL runs |

Scenarios 5 and 6 use `continue-on-error: true`. A follow-up step checks the step
`outcome` and the `failure-category` output.

## Running it

GitHub → Actions → **Integration (DEV Fabric)** → *Run workflow*.

To test a change before it is merged, run the workflow on your branch.
`uses: ./` exercises the action code checked out from that branch.

## Manual verification checklist

After a green run, check these by hand in the DEV warehouse:

- [ ] `wdit.Customer` has columns `CustomerId, CustomerName, Email`, and no `CustomerType`.
- [ ] The rows in `wdit.Customer` survived. Insert a row before scenario 3 and confirm it
      is still there afterwards.
- [ ] `wdit.vw_a_summary` can be queried.
- [ ] The workflow log contains no secret, token or `Authorization` value. Search for
      the first 6 characters of the secret.
- [ ] The failure scenarios show GitHub annotations on the right files.
