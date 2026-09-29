# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/). Until 1.0.0, minor versions
may contain breaking changes to inputs or behaviour.

## [Unreleased]

## [0.1.0]

### Added

- Service Principal authentication
- Fabric Warehouse discovery
- SQL endpoint discovery
- Fabric Git database-project discovery
- phased object deployment
- safe new-table deployment
- safe nullable-column additions
- CREATE OR ALTER handling for views
- multi-pass view dependency resolution
- structured deployment summary
- initial error classification
- GitHub Actions outputs

### Notes

- Functions and stored procedures are also deployed with an in-memory
  `CREATE OR ALTER` rewrite and the same multi-pass engine as views.
- All table changes are planned before any is executed; one unsafe change blocks
  every table change in that run.
- Authentication uses the Entra ID client-credentials endpoint directly and
  go-sqlcmd's `ActiveDirectoryServicePrincipal` method; the Azure CLI is not required.
