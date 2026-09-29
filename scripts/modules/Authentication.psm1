Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

<#
  Service Principal (client-credentials) authentication against Microsoft Entra ID.

  Uses the OAuth2 token endpoint directly instead of `az login`: same Service
  Principal model, but the secret travels only in an HTTPS request body - never
  on a process command line (visible to other processes) and never in the Azure
  CLI token cache on a shared runner.
#>

$script:FabricScope = 'https://api.fabric.microsoft.com/.default'
$script:SqlScope = 'https://database.windows.net/.default'

function Get-FabricScope { return $script:FabricScope }
function Get-SqlScope { return $script:SqlScope }

function Add-SecretMask {
    <# Registers a value with the GitHub runner so it is redacted from all later logs. #>
    param([AllowEmptyString()][string]$Value)
    if ($env:GITHUB_ACTIONS -eq 'true' -and -not [string]::IsNullOrEmpty($Value)) {
        Write-Host "::add-mask::$Value"
    }
}

function Get-EntraAccessToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$Scope,
        [string]$AuthorityHost = 'https://login.microsoftonline.com'
    )

    # TenantId is GUID-validated by the entry script, so it is safe in the URL path.
    $uri = "$AuthorityHost/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -MaximumRetryCount 2 -RetryIntervalSec 3
    }
    catch {
        # Entra error bodies contain AADSTS codes/descriptions but never the secret.
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Stop-Deployment -Category 'AUTHENTICATION_FAILED' -Phase 'Authentication' `
            -Message "Could not obtain an access token for scope '$Scope'." -OriginalError $detail `
            -SuggestedAction 'Verify tenant-id, client-id and client-secret (and that the secret has not expired).'
    }

    # Property probe instead of $response.access_token: under StrictMode a missing
    # property would throw a generic error and lose the AUTHENTICATION_FAILED category.
    if (-not ($response -and $response.PSObject.Properties['access_token'] -and $response.access_token)) {
        Stop-Deployment -Category 'AUTHENTICATION_FAILED' -Phase 'Authentication' -Message "Token response for '$Scope' did not contain an access token."
    }
    Add-SecretMask $response.access_token
    return [string]$response.access_token
}

Export-ModuleMember -Function Get-FabricScope, Get-SqlScope, Add-SecretMask, Get-EntraAccessToken
