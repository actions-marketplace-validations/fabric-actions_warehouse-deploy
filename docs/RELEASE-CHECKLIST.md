# Release checklist: v0.1.0

Work through this list **in order**. Nothing in this repository creates tags,
releases or Marketplace listings automatically.

## 1. Code review

- [ ] Independent code review is complete and all findings are resolved or recorded
      as known limitations.
- [ ] High-risk areas are reviewed explicitly: SQL text parsing, sqlcmd
      authentication, error classification, and secret handling.
- [ ] No `TODO`, `FIXME` or debug output is left in `scripts/`.

## 2. Local validation

```powershell
./tests/Validate-Repository.ps1
Invoke-Pester ./tests/unit -Output Detailed
```

- [ ] Validation passes, with 0 PSScriptAnalyzer findings.
- [ ] Every Pester test passes.

## 3. CI

- [ ] `Test` workflow is green on `main` (Ubuntu and Windows).
- [ ] `Release validation` workflow run manually with `version = 0.1.0` is green.

## 4. Live verification (DEV Fabric)

- [ ] `Integration (DEV Fabric)` workflow is green: all six scenarios behave as documented.
- [ ] Manual checklist in [INTEGRATION-TESTING.md](INTEGRATION-TESTING.md) is complete.
- [ ] The go-sqlcmd default version (`1.8.0`) downloads on `ubuntu-latest`, and the
      `ActiveDirectoryServicePrincipal` login works against the Fabric endpoint.
- [ ] At least one run against a **copy** of a real project's Fabric Git folder.

## 5. Security

- [ ] Search the full integration log for the secret, the tokens (`eyJ`) and `Bearer`:
      no matches.
- [ ] `action.yml` contains no `${{ inputs.* }}` inside `run:` (the validation script
      checks this).
- [ ] Temporary directories under `$RUNNER_TEMP/warehouse-deploy-*` are removed after
      both successful and failed runs.
- [ ] Review the go-sqlcmd download: decide whether to add checksum pinning before a
      public Marketplace listing.

## 6. Documentation

- [ ] README inputs and outputs match `action.yml`. The validation script checks the
      outputs automatically.
- [ ] README, `examples/*.yml` and CHANGELOG all say `v0.1.0`. The release validation
      workflow checks this.
- [ ] Limitations section is accurate for this release.
- [ ] CHANGELOG `[0.1.0]` section is final. Add the release date.

## 7. Publish (maintainer, manual; only after steps 1–6)

- [ ] Merge to `main`.
- [ ] `git tag -a v0.1.0 -m "v0.1.0"` on the reviewed commit, then `git push origin v0.1.0`.
- [ ] Create the GitHub Release from the tag, with the CHANGELOG section as the notes.
- [ ] Optional: tick *Publish this Action to the GitHub Marketplace*. This needs
      `action.yml` at the repository root and a unique `name` ("Fabric Warehouse
      Deploy"). Check that no other Marketplace action uses the name.
- [ ] Do **not** create a floating `v1` or `v0` tag.

## 8. After release

- [ ] Try `uses: fabric-actions/warehouse-deploy@v0.1.0` from a separate consumer
      repository.
- [ ] Open issues for any findings from the first real deployments.
