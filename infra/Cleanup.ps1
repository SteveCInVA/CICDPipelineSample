#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'rg-hello-world'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzureCli {
    param([string[]] $Arguments)

    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit code $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    $result
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it and run az login before cleaning up.'
}

Invoke-AzureCli -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId, '--output', 'none'
) | Out-Null

$groupExists = Invoke-AzureCli -Arguments @(
    'group', 'exists', '--name', $ResourceGroupName,
    '--subscription', $SubscriptionId, '--output', 'tsv'
)
if ($groupExists -notin @('true', 'false')) {
    throw "Unexpected resource group existence response: $groupExists"
}
if ($groupExists -eq 'false') {
    Write-Host "Resource group '$ResourceGroupName' does not exist in subscription '$SubscriptionId'. Nothing to clean up."
    return
}

if ($PSCmdlet.ShouldProcess(
    "$SubscriptionId/$ResourceGroupName",
    'Permanently delete the resource group and ALL resources it contains, including container images and logs'
)) {
    Invoke-AzureCli -Arguments @(
        'group', 'delete', '--name', $ResourceGroupName,
        '--subscription', $SubscriptionId, '--no-wait', '--yes', '--output', 'none'
    ) | Out-Null
    Write-Host "Deleted resource group '$ResourceGroupName' in subscription '$SubscriptionId'."
}
