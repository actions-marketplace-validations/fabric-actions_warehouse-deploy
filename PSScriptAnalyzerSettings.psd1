@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Logging deliberately uses Write-Host (information stream) so log lines are
        # never mixed into function return values.
        'PSAvoidUsingWriteHost'
        # Counters/verbs like "Invoke-*Deployment" are internal module functions,
        # not user-facing cmdlets; ShouldProcess would add no value in CI.
        'PSUseShouldProcessForStateChangingFunctions'
        # Plural nouns (Get-FabricWarehouses, Publish-ActionOutputs) read better here.
        'PSUseSingularNouns'
    )
}
