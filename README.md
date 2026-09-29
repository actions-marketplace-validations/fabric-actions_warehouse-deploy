# Fabric Warehouse Deploy

**Dependency-aware CI/CD deployment for Microsoft Fabric Warehouse database projects.**

[![Test](https://github.com/fabric-actions/warehouse-deploy/actions/workflows/test.yml/badge.svg)](https://github.com/fabric-actions/warehouse-deploy/actions/workflows/test.yml)

```yaml
- uses: actions/checkout@v4
- uses: fabric-actions/warehouse-deploy@v0.1.0
  with:
    warehouse-name: ${{ vars.WAREHOUSE_NAME }}
    warehouse-folder: ${{ vars.WAREHOUSE_FOLDER }}
    workspace-id: ${{ secrets.FABRIC_WORKSPACE_ID }}
    tenant-id: ${{ secrets.FABRIC_TENANT_ID }}
    client-id: ${{ secrets.FABRIC_CLIENT_ID }}
    client-secret: ${{ secrets.FABRIC_CLIENT_SECRET }}
```

> **Status: v0.1.0, pre-1.0.** The action does useful work today, and it is
> deliberately conservative. Inputs and behaviour may change before 1.0. Read
> [Supported schema evolution](#supported-schema-evolution) and
> [Limitations](#limitations) before you point it at production. This release has
> not yet been validated against a live Fabric warehouse; see the release checklist.

---

## Contents

1. [What it solves](#what-it-solves)
2. [Why running SQL files alphabetically fails](#why-running-sql-files-alphabetically-fails)
3. [Key features](#key-features)
4. [What v0.1.0 covers](#what-v010-covers)
5. [Usage](#usage)
6. [Inputs](#inputs)
7. [Outputs](#outputs)
8. [Authentication](#authentication)
9. [Required Fabric permissions](#required-fabric-permissions)
10. [Supported objects](#supported-objects)
11. [Supported schema evolution](#supported-schema-evolution)
12. [Unsupported and destructive changes](#unsupported-and-destructive-changes)
13. [How a deployment runs](#how-a-deployment-runs)
14. [Example logs](#example-logs)
15. [Error handling](#error-handling)
16. [Security](#security)
17. [Limitations](#limitations)
18. [Versioning](#versioning)
19. [Roadmap](#roadmap)
20. [Contributing](#contributing)
21. [License](#license)

---

## What it solves

When a Fabric Warehouse is connected to Git, Fabric writes a SQL database project
into the repository: one `.sql` file for each table, view, function and procedure, in
a folder layout that Fabric controls. To deploy that project to another warehouse, for
example TEST or PROD, you need more than a loop that runs the files:

- objects must be created in dependency order;
- objects that already exist must be updated, not re-created;
- existing tables that hold data must never be dropped;
- failures must come with a useful message, not a bare `sqlcmd` exit code.

This action handles all of that. Your repository stays the way Fabric generated it. You
don't need numeric file prefixes, a custom folder layout or deployment scripts of
your own.

## Why running SQL files alphabetically fails

A typical first pipeline does this:

```powershell
Get-ChildItem -Recurse -Filter *.sql | Sort-Object FullName | ForEach-Object {
    sqlcmd -S $endpoint -d $db -G -b -i $_.FullName
}
```

| Problem | What happens |
|---|---|
| **View dependencies** | `vw_sales_summary` reads from `vw_sales_totals_daily`, but it sorts first, so the deployment fails even though both files exist. |
| **Existing views** | `CREATE VIEW` fails on every deployment after the first, because the view already exists. |
| **Existing tables** | `CREATE TABLE` fails because the table exists. The only "fix" is to drop it, and the data goes with it. |
| **New columns** | A column added in Fabric never reaches an existing table. |
| **Errors** | `sqlcmd -b` sets an exit code, but PowerShell does not stop on native exit codes. Failures can pass silently. When they are caught, the log shows only the exit code. |

## Key features

- **Works with the Fabric Git layout as it is.** The action never renames, moves or
  edits a source file.
- **Dependency-aware view deployment.** Views are deployed in repeated passes. Each pass
  retries the views that failed while at least one view succeeds, so order is resolved
  without numeric prefixes. The number of passes is bounded, so it cannot loop forever.
- **Idempotent views, functions and procedures.** `CREATE` becomes `CREATE OR ALTER` in
  memory at deploy time. The committed file is not changed.
- **Safe handling of existing tables.** An existing table is compared with its source
  definition, and missing nullable columns are added with `ALTER TABLE … ADD`. Tables
  are never dropped or re-created.
- **Plan before execute.** Every table change is planned first. If any change is unsafe,
  the run stops before any table DDL runs.
- **Structured diagnostics.** Every failure reports a category, phase, object, file, the
  original SQL error and a suggested action. Failures also appear as GitHub annotations
  on the file.
- **Built for GitHub Actions.** The action is a single step with typed outputs, and a
  deployment summary is printed even when the run fails.

## What v0.1.0 covers

v0.1.0 is a deliberately conservative first release. It automates changes it can
prove are safe, and it **stops with a clear error** whenever it can't. This section
summarises the whole contract. The details are in the sections linked below.

### Covered in v0.1.0

| Area | What the action does |
|---|---|
| Authentication | Service Principal with a client secret (Entra ID client credentials) |
| Discovery | Finds the warehouse by display name in the workspace and resolves its SQL endpoint through the Fabric REST API |
| Fabric Git layout | Reads the Fabric-generated `<Name>.Warehouse` folder as it is. Files are never renamed, moved or edited |
| Classification | Schemas, tables, views, functions and stored procedures. The folder and the `CREATE` statement must agree |
| Deployment order | Schemas → tables → functions → views → stored procedures, in a deterministic path order within each phase |
| Schemas | Created if missing, skipped if they exist |
| New tables | Created by running the original Fabric `CREATE TABLE` file |
| Existing tables | Detected and never re-created. Columns that already exist are skipped |
| New columns | Added with `ALTER TABLE … ADD` when declared `NULL`, with no default, identity, computed expression or inline constraint |
| Views | Deployed as `CREATE OR ALTER VIEW` (rewritten in memory), so repeat deployments succeed |
| View dependencies | Multi-pass deployment resolves order automatically, with a bounded number of passes |
| Functions and procedures | Deployed as `CREATE OR ALTER`, with the same multi-pass handling |
| Unknown SQL | Reported and **not executed**. Set `fail-on-unclassified-sql: true` to make it fail the run |
| Errors | Categorised errors with the original SQL error, phase, object, file and a suggested action, plus GitHub annotations |
| Reporting | A deployment summary on every run, successful or not, and step outputs for later steps |
| Idempotency | Running the same deployment twice succeeds, and the second run creates and alters nothing |

### What makes a deployment fail

These conditions stop the run with a non-zero exit code and a named error category.
Nothing is changed silently to "make it work".

| Situation | Result | Is anything applied? |
|---|---|---|
| A missing, malformed or non-GUID input, or a `warehouse-folder` outside the repository | `INVALID_INPUT` | No. The run stops before connecting |
| Wrong tenant, client or secret, an expired secret, or SQL login refused | `AUTHENTICATION_FAILED` | No |
| The workspace can't be read by the principal | `WAREHOUSE_ACCESS_FAILED` | No |
| No warehouse with that name, or several with the same name | `WAREHOUSE_NOT_FOUND` | No |
| The warehouse has no SQL endpoint yet | `SQL_ENDPOINT_DISCOVERY_FAILED` | No |
| Unknown SQL files while `fail-on-unclassified-sql: true` | `UNCLASSIFIED_SQL` | No. The run stops before connecting |
| An existing table gains a `NOT NULL` column, a column with `DEFAULT`, `IDENTITY` or an inline constraint, a computed column, or a column with no explicit nullability | `UNSAFE_SCHEMA_CHANGE` | **No table changes at all**, including safe ones in other tables |
| A column or table name differs from the target only by letter case (a possible rename) | `UNSAFE_SCHEMA_CHANGE` | No table changes |
| The `CREATE TABLE` of an existing table can't be parsed, e.g. `CREATE TABLE … AS SELECT` | `TABLE_PARSE_FAILED` | No table changes |
| A view references an object that doesn't exist, has invalid SQL, or is part of a circular reference | `VIEW_DEPLOYMENT_FAILED`, with every remaining SQL error | Earlier phases, and views that did succeed, stay applied. Later phases don't run |
| A function or procedure fails to deploy | `UNRESOLVED_DEPENDENCY_OR_INVALID_SQL`, with every remaining SQL error | Earlier phases stay applied |
| A `CREATE TABLE`, `ALTER TABLE` or `CREATE SCHEMA` statement is rejected by the warehouse | The SQL error category | Earlier statements stay applied |

There are no transactions across phases, but everything v0.1 applies is additive or
`CREATE OR ALTER`. Once you fix the cause, re-running the deployment is safe.

### Not handled in v0.1.0, and not reported

These changes are **not applied, and no warning is shown**. Make them manually until a
later version covers them:

- a changed data type, length or precision on an existing column, e.g. `VARCHAR(50)` → `VARCHAR(100)`;
- a nullability change on an existing column (`NULL` ↔ `NOT NULL`);
- a collation or default change on an existing column;
- changes to primary keys, foreign keys, unique constraints or indexes;
- distribution or partitioning changes.

The action **never** drops, renames or re-creates a table or column. A column that
exists in the warehouse but not in source is kept, and a warning is shown.

Security objects other than schemas, such as roles, users and permissions, are
reported as unclassified and never executed.

See [Roadmap](#roadmap) for when each of these gaps is planned to be closed.

## Usage

### Basic

See [`examples/basic.yml`](examples/basic.yml).

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: fabric-actions/warehouse-deploy@v0.1.0
        with:
          warehouse-name: SalesWarehouse
          warehouse-folder: SalesWarehouse.Warehouse
          workspace-id: ${{ secrets.FABRIC_WORKSPACE_ID }}
          tenant-id: ${{ secrets.FABRIC_TENANT_ID }}
          client-id: ${{ secrets.FABRIC_CLIENT_ID }}
          client-secret: ${{ secrets.FABRIC_CLIENT_SECRET }}
```

### Using outputs

```yaml
      - name: Deploy
        id: fabric
        uses: fabric-actions/warehouse-deploy@v0.1.0
        with: { ... }

      - name: Show result
        if: always()
        run: |
          echo "Status:         ${{ steps.fabric.outputs.deployment-status }}"
          echo "Views deployed: ${{ steps.fabric.outputs.views-deployed }}"
```

### TEST → PROD promotion with approval

See [`examples/production.yml`](examples/production.yml). It uses GitHub environments
for per-environment secrets and required reviewers, and a `concurrency` group so two
deployments never run against the same warehouse at once.

### Runner requirements

- `pwsh` 7.2 or later. GitHub-hosted Ubuntu, Windows and macOS runners include it.
- Outbound HTTPS to `login.microsoftonline.com`, `api.fabric.microsoft.com` and
  `github.com` (to download go-sqlcmd), and TDS on port 1433 to
  `*.datawarehouse.fabric.microsoft.com`.
- Linux x64 is the target platform. Windows and macOS are covered by unit tests only.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `warehouse-name` | yes | | Display name of the target warehouse. Matched case-insensitively within the workspace. |
| `warehouse-folder` | yes | | Path, relative to the repository root, of the Fabric-generated warehouse folder, e.g. `SalesWarehouse.Warehouse`. It must be inside the workspace. |
| `workspace-id` | yes | | Fabric workspace ID (GUID). |
| `tenant-id` | yes | | Entra tenant ID (GUID). |
| `client-id` | yes | | Service Principal application ID (GUID). |
| `client-secret` | yes | | Service Principal secret. **Always pass it from a secret.** |
| `fail-on-unclassified-sql` | no | `false` | When `true`, any SQL file that cannot be classified fails the run before the action connects. When `false`, such files produce warnings and are skipped. |
| `max-view-passes` | no | `0` | Maximum number of view deployment passes. `0` means automatic, which is the number of views and the most that can ever be needed. |
| `verbose` | no | `false` | Debug logging. It never includes secrets or tokens. |
| `sqlcmd-version` | no | `1.8.0` | [go-sqlcmd](https://github.com/microsoft/go-sqlcmd/releases) version to download. |

## Outputs

| Output | Description |
|---|---|
| `deployment-status` | `SUCCESS` or `FAILED` |
| `failure-category` | Error category on failure (see [Error handling](#error-handling)); empty on success |
| `warehouse-id` | ID of the resolved warehouse |
| `warehouse-name` | Display name of the resolved warehouse |
| `tables-created` | Tables created from source |
| `tables-existing` | Source tables that already existed |
| `columns-added` | Nullable columns added to existing tables |
| `views-deployed` | Views deployed (`CREATE OR ALTER`) |
| `view-passes` | Passes needed to resolve view dependencies |
| `unclassified-files` | SQL files that were not classified and not executed |

Outputs are written through `$GITHUB_OUTPUT`, even when the deployment fails. To read
them after a failure, use `if: always()` on the later step or `continue-on-error: true`
on the deploy step.

## Authentication

v0.1 authenticates with a **Service Principal and a client secret**:

1. The action requests tokens from the Entra ID client-credentials endpoint:
   `https://api.fabric.microsoft.com/.default` for the Fabric REST API, and
   `https://database.windows.net/.default` to check early that SQL access works.
2. It calls the Fabric REST API to find the warehouse and its SQL connection string.
3. go-sqlcmd connects with `--authentication-method ActiveDirectoryServicePrincipal`.
   The secret is passed only through the `SQLCMDPASSWORD` environment variable of the
   step process. It never appears on a command line, and the variable is removed when
   the step finishes.

The Azure CLI is not used, so a hosted runner keeps no `az` token cache. Support for
GitHub OIDC (federated credentials, no secret) is planned. See the [roadmap](#roadmap).

## Required Fabric permissions

1. **Tenant setting.** In the Fabric admin portal, turn on *Service principals can use
   Fabric APIs*. You can scope it to a security group that contains the principal.
2. **Workspace role.** Add the Service Principal, or a group that contains it, to the
   workspace as **Contributor** or higher. Contributor is enough to read warehouse
   metadata and run DDL.
3. You don't need an Azure subscription role.

## Supported objects

Files are classified by **both** their Fabric folder and their content. A file must
be in a recognised folder and must contain the matching `CREATE` statement. Anything
else is reported as *unclassified* and **never executed**.

| Folder (case-insensitive, `/` or `\`) | Required statement | Phase | Re-deploy behaviour |
|---|---|---|---|
| `Security/`, `Schemas/`, or a top-level `CREATE SCHEMA` file | `CREATE SCHEMA` | 1 | Skipped if the schema exists (checked in `sys.schemas`) |
| `Tables/` | `CREATE TABLE` | 2 | Created if missing. If it exists, safe column additions only |
| `Functions/` | `CREATE FUNCTION` | 3 | `CREATE OR ALTER`, multi-pass |
| `Views/` | `CREATE VIEW` | 4 | `CREATE OR ALTER`, multi-pass |
| `StoredProcedures/`, `Stored Procedures/` | `CREATE PROCEDURE` / `PROC` | 5 | `CREATE OR ALTER`, multi-pass |

Within a phase, files run in a deterministic path order. The `CREATE` → `CREATE OR
ALTER` rewrite changes only the first real `CREATE <kind>` token. Text in comments,
string literals and `[bracketed identifiers]` is never matched.

## Supported schema evolution

For a table that already exists in the target:

| Source change | v0.1 behaviour |
|---|---|
| Column exists in both | No action (`[EXISTS]`) |
| New column declared **`NULL`**, no default, identity, computed expression or inline constraint | `ALTER TABLE [s].[t] ADD [col] <definition from source>` |
| Column exists only in the target | **Kept.** A warning is shown. It is never dropped |

That is all v0.1 changes on an existing table.

## Unsupported and destructive changes

These stop the deployment with `UNSAFE_SCHEMA_CHANGE`, **before any table DDL runs**:

- a new column that is `NOT NULL`;
- a new column with no explicit `NULL` or `NOT NULL`;
- a new column with `DEFAULT`, `IDENTITY`, a computed expression, or an inline
  `PRIMARY KEY`, `UNIQUE`, `CHECK` or `REFERENCES` constraint;
- a column or table name that differs from the target **only by case**, which might be
  a rename.

v0.1 **does not detect** changes to existing columns. Changes of data type, length,
nullability, collation or constraints on an existing column are **silently not
applied**. The same is true for primary keys, foreign keys, indexes, distribution and
partitioning. The action never drops, renames or re-creates anything.

Example:

```text
Category:    UNSAFE_SCHEMA_CHANGE
Phase:       Tables
Object type: Table

Reason:
  1 table change(s) cannot be deployed automatically. No table changes were made.

Original error:
  Table: dbo.Customer
  Column: CustomerType
  File: dbo/Tables/Customer.sql
  Reason: New NOT NULL columns are not automatically deployed in v0.1.

Suggested action:
  Provide an explicit migration strategy (e.g. add the column as NULL, backfill, then tighten), or deploy the change manually.
```

## How a deployment runs

```text
validate inputs ─► discover & classify files ─► (strict? fail on unclassified)
      ─► Entra tokens ─► Fabric API: find warehouse + SQL endpoint ─► install go-sqlcmd
      ─► connectivity probe
      ─► Schemas ─► Tables (plan all, then execute) ─► Functions ─► Views ─► Procedures
      ─► summary + outputs (always)
```

**Multi-pass algorithm** (views, functions, procedures):

```text
pending = all objects
while pending not empty:
    if passes == limit: fail (limit reached)
    run every pending object; keep the failures
    if every object in the pass failed: fail and print every remaining SQL error
```

Each pass either fails or deploys at least one more object, so the loop runs at most
N passes for N objects. An authentication error stops the loop at once instead of
being retried.

A failure in a pass is **not** assumed to be a dependency problem. The real SQL error
of every object is kept and printed when the run stops.

## Example logs

### Successful deployment (fresh warehouse, views in the wrong alphabetical order)

```text
==================================================
FABRIC WAREHOUSE DEPLOY
==================================================
Warehouse folder: SalesWarehouse.Warehouse
Discovered 7 SQL file(s): 1 schema, 2 table, 1 function, 2 view, 1 procedure, 0 unclassified
Warehouse: SalesWarehouse
Warehouse ID: 5b3e0c1a-...

==================================================
SCHEMAS
==================================================
[CREATE SCHEMA] sales

==================================================
TABLES
==================================================
[CREATE TABLE] dbo.Customer
[CREATE TABLE] sales.Orders

==================================================
VIEW DEPLOYMENT PASS 1
==================================================

[VIEW] dbo.vw_sales_summary
DEFERRED

[VIEW] dbo.vw_sales_totals_daily
SUCCESS

Pass result:
1 successful
1 deferred

==================================================
VIEW DEPLOYMENT PASS 2
==================================================

[VIEW] dbo.vw_sales_summary
SUCCESS

Pass result:
1 successful
0 deferred

==================================================
FABRIC WAREHOUSE DEPLOYMENT SUMMARY
==================================================

Warehouse:
SalesWarehouse

Schemas:
  Created:               1
  Already existing:      0

Tables:
  Created:               2
  Already existing:      0
  Columns added:         0

Views:
  Deployed:              2
  Passes required:       2

Functions:
  Processed:             1

Stored Procedures:
  Processed:             1

Unclassified SQL:
  Files:                 0

Result:
SUCCESS
==================================================
```

### Existing table with a new nullable column

```text
[EXISTING TABLE] dbo.Customer
  [NEW COLUMN] Email
  [ADD COLUMN] dbo.Customer.Email  (VARCHAR (320) NULL)
[EXISTING TABLE] sales.Orders
```

### Failed deployment (unresolvable view dependency)

```text
==================================================
VIEW DEPLOYMENT PASS 2
==================================================

[VIEW] dbo.vw_sales_summary
DEFERRED

Pass result:
0 successful
1 deferred

==================================================
VIEW DEPLOYMENT FAILED
==================================================
No progress in the last pass: the remaining failures cannot be fixed by reordering (missing dependency, invalid SQL or circular reference).

dbo/Views/vw_sales_summary.sql

SQL ERROR:
  Msg 208, Level 16, State 1, Line 1
  Invalid object name 'dbo.vw_finance_monthly'.

Classification:
UNRESOLVED_DEPENDENCY_OR_INVALID_SQL

==================================================
DEPLOYMENT FAILED
==================================================
Category:    VIEW_DEPLOYMENT_FAILED
Phase:       Views
Object type: View
Object:      dbo.vw_sales_summary
File:        dbo/Views/vw_sales_summary.sql
...
Result:
FAILED (VIEW_DEPLOYMENT_FAILED)
```

The step exits with a non-zero code, and an error annotation is attached to
`SalesWarehouse.Warehouse/dbo/Views/vw_sales_summary.sql`.

## Error handling

Every failure has this shape:

| Field | Meaning |
|---|---|
| Category | One of the values below |
| Phase | Validation, Discovery, Authentication, Setup, Connect, Schemas, Tables, Functions, Views, StoredProcedures |
| Object type / Object | For example `View` / `dbo.vw_sales_summary` |
| File | Path relative to the warehouse folder |
| Original error | The unmodified SQL, HTTP or Entra error text |
| Suggested action | Given where the fix is known |

| Category | Typical cause |
|---|---|
| `INVALID_INPUT` | A required input is missing, an ID is not a GUID, or the folder is outside the workspace |
| `AUTHENTICATION_FAILED` | Wrong tenant, client or secret, an expired secret, or `Login failed` from SQL |
| `WAREHOUSE_ACCESS_FAILED` | The workspace can't be read (HTTP 401/403/404) |
| `WAREHOUSE_NOT_FOUND` | No warehouse with that name, or several (the name is ambiguous) |
| `SQL_ENDPOINT_DISCOVERY_FAILED` | The warehouse has no connection string yet, or its format is unexpected |
| `SQLCMD_FAILED` | Download or install failed, or a SQL error that fits no other category |
| `TABLE_PARSE_FAILED` | The `CREATE TABLE` of an existing table couldn't be parsed |
| `UNSAFE_SCHEMA_CHANGE` | See [Unsupported and destructive changes](#unsupported-and-destructive-changes) |
| `VIEW_DEPLOYMENT_FAILED` | Views remain undeployed after the pass loop stopped |
| `UNRESOLVED_DEPENDENCY_OR_INVALID_SQL` | A function or procedure failed with a missing object or bad SQL. Also shown per object in view failures |
| `UNCLASSIFIED_SQL` | Strict mode found files that couldn't be classified |
| `UNKNOWN_ERROR` | A bug in the action. Please open an issue with the log |

Exit codes: `0` on success, `1` on any failure.

## Security

- **Secrets never reach logs.** The client secret and access tokens are registered
  with `::add-mask::`. No command line contains a credential. Bearer tokens are passed
  only in request headers, and Authorization headers are never logged. Verbose mode
  logs none of these.
- **No script injection.** `action.yml` passes every input through `env:` and never
  interpolates `${{ inputs.* }}` into script text. IDs must be GUIDs.
  `warehouse-folder` must resolve inside `$GITHUB_WORKSPACE`. The SQL endpoint returned
  by the API must be a plain host name before it is passed to sqlcmd.
- **Untrusted text is neutralised.** SQL error text that starts a line with `::` is
  escaped so it can't issue workflow commands. Annotation values are escaped as the
  workflow-command spec requires.
- **Temporary files hold only SQL.** They are written to a private directory under
  `$RUNNER_TEMP` and deleted when the step finishes, whether it succeeds or fails.
- **Pinned tooling.** go-sqlcmd is downloaded at a pinned version. A `sqlcmd` already on
  the runner is never used. The download is **not** checksum-verified in v0.1. See
  [Limitations](#limitations).
- **Least privilege.** Give the principal Contributor on one workspace, not Admin, and
  use a separate principal for each environment.
- **Pin the action.** Consumers who need supply-chain guarantees should pin to a full
  commit SHA instead of a tag.

## Limitations

- **Existing columns are not compared.** Changes of type, length, nullability or
  constraints on an existing column are not applied and not reported (planned for v0.2).
- **The multi-pass engine costs extra calls.** A view that fails in pass *n* runs again
  in pass *n+1*. For a chain of dependencies *k* deep, some views run up to *k* times.
- **Functions and procedures are deployed with `CREATE OR ALTER`.** If Fabric rejects
  that form for a particular object, the error is reported as it is.
- **The table parser is not a full T-SQL parser.** It handles the layout Fabric
  generates: nested parentheses, quoted and bracketed identifiers, string literals, and
  line and nested block comments. `CREATE TABLE AS SELECT` isn't supported for an
  existing table, and the run fails with `TABLE_PARSE_FAILED`.
- **Metadata query limitation.** Column and table names that contain a `|` character
  are not supported, because the metadata query uses `|` as its separator.
- **Other object types are not deployed.** Security objects other than schemas (roles,
  users, grants) are reported as unclassified and not executed.
- **No transactions across files.** A failure in a later phase leaves the earlier
  phases applied. Every applied change is additive or `CREATE OR ALTER`, so re-running
  after a fix is safe.
- **No locking.** Use a workflow `concurrency` group so two runs never target the same
  warehouse at once.
- **go-sqlcmd download integrity.** The download relies on HTTPS to GitHub Releases,
  and no checksum is verified.

## Versioning

This project follows [Semantic Versioning](https://semver.org/).

- Pin an exact release: `fabric-actions/warehouse-deploy@v0.1.0`.
- No floating major tag (`@v1`) is published until 1.0.0. The action will be declared
  stable only after several real warehouse deployments, a security review, and a
  frozen input contract.
- Before 1.0.0, a minor version (0.x) may change inputs or behaviour. Every change is
  listed in [CHANGELOG.md](CHANGELOG.md).

## Roadmap

Everything below is **planned, not implemented**. Versions and scope may change as
real deployments give feedback. The v0.1 architecture keeps each step additive: table
planning is separate from execution, the multi-pass engine is generic, and every
sqlcmd call goes through a single module.

### v0.2.0: Deployment planning and better schema comparison

This release closes the biggest v0.1 gap: changes to existing columns that are
currently not reported.

- **Dry-run mode:** show exactly what would change without touching the warehouse.
- **Deployment plan** with an action for each object:
  ```text
  CREATE  dbo.Customer
  ALTER   dbo.Orders + SourceSystem
  SKIP    dbo.Account
  BLOCKED dbo.Payment.Amount datatype mismatch
  ```
- Compare data type, length and precision between source and target columns.
- Detect length widening, e.g. `VARCHAR(50)` → `VARCHAR(100)`.
- Compare nullability.
- Warn about every unsupported change instead of skipping it silently.
- A JSON deployment plan as a downloadable artifact.
- A GitHub step summary of the plan and result.

Changes stay non-destructive by default.

### v0.3.0: Dependency engine

- Discover view dependencies by parsing references.
- Build a dependency graph and deploy in topological order, so each view runs once.
- Detect circular dependencies and report the cycle explicitly.
- Impacted-object analysis: which views depend on a changed object.
- The multi-pass engine stays available as a fallback.

### v0.4.0: Functions and stored procedures

v0.1 already deploys functions and procedures with `CREATE OR ALTER` and multi-pass
retries. v0.4 builds on that:

- dependency management between functions, procedures and views;
- dedicated retry handling for programmable objects;
- improved object classification, including more object types.

### v0.5.0: Change-aware deployment

- Detect changed SQL objects from the Git diff.
- Deploy only the changed objects plus the objects that depend on them.
- A full-deployment override.
- A deployment preview on pull requests.

### v0.6.0: Enterprise reporting

- A GitHub job summary for every deployment.
- A JSON deployment report as a downloadable artifact.
- Deployment timings and per-object status and duration.
- GitHub annotations for every warning and error, linked to files.
- Audit-friendly logs.

### v0.7.0: Identity and authentication

- GitHub OIDC with Azure federated identity, so no client secret is needed.
- Less reliance on client secrets overall. OIDC becomes the recommended setup.
- Managed identity where it applies, e.g. self-hosted runners in Azure.

### v0.8.0: Policy and safety

- Allow and deny patterns for objects.
- Environment protections, e.g. stricter rules for production.
- Explicit policies for destructive changes, which are opt-in only.
- Configurable retry behaviour and timeouts.
- Production safeguards.

### v0.9.0: Azure DevOps integration

The core engine stays unchanged. v0.9 adds a wrapper for Azure Pipelines:

- an Azure DevOps custom task (`task.json`) and extension manifest;
- VSIX packaging and a Marketplace release process;
- pipeline task inputs that mirror the action inputs;
- Azure Pipelines examples.

### v1.0.0: Stable public release

v1.0.0 will be released only when:

- the action has run against multiple real warehouse implementations and proven itself in production;
- inputs and outputs are stable, with a documented backwards-compatibility policy;
- the parser has been hardened and a security review is complete;
- the Azure DevOps wrapper has been validated;
- the documentation is complete.

Until then, releases are `0.x` and may change inputs between minor versions (see
[Versioning](#versioning)).

## Contributing

Issues and pull requests are welcome.

```powershell
# Requirements: PowerShell 7.2+, Pester 5.x, PSScriptAnalyzer
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

./tests/Validate-Repository.ps1                  # syntax, lint, action.yml contract
Invoke-Pester ./tests/unit -Output Detailed      # unit + orchestration tests (no Fabric needed)
```

- The unit tests need no Fabric access. `Orchestration.Tests.ps1` runs the real entry
  script against a stateful fake `sqlcmd`.
- To test against a live warehouse, see [docs/INTEGRATION-TESTING.md](docs/INTEGRATION-TESTING.md).
- Please include a test for any parser or classification change. Parser bugs are the
  riskiest kind in this project.
- Keep the design principles: never modify Fabric's folder structure, automate only
  safe changes, never hide an SQL error.

Repository layout:

```text
action.yml                     interface only; runs scripts/deploy-warehouse.ps1
scripts/deploy-warehouse.ps1   entry point: input validation + phase orchestration
scripts/modules/
  ErrorHandling.psm1           failure objects, categories, safe logging/annotations
  SqlParsing.psm1              comment/string-aware SQL text utilities
  SqlExecution.psm1            go-sqlcmd install + the only sqlcmd invocation
  Authentication.psm1          Entra client-credentials tokens
  FabricApi.psm1               warehouse + SQL endpoint discovery
  ObjectDiscovery.psm1         file discovery and classification
  SchemaDeployment.psm1        CREATE SCHEMA if missing
  TableDeployment.psm1         CREATE TABLE parser, change planner, executor
  ViewDeployment.psm1          CREATE OR ALTER rewrite + multi-pass engine
  DeploymentReport.psm1        summary + GitHub outputs
tests/unit/                    Pester tests
tests/fixtures/                Fabric-shaped sample warehouse
tests/integration/             DEV Fabric scenarios (manual workflow)
docs/                          integration testing, release checklist
```

## License

[MIT](LICENSE). "Microsoft Fabric" is a trademark of Microsoft Corporation. This
project is not affiliated with or endorsed by Microsoft.
