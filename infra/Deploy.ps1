#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = 'rg-hello-world',

    [ValidateNotNullOrEmpty()]
    [string] $DeploymentName = 'hello-world-infra',

    [ValidateNotNullOrEmpty()]
    [string] $TemplateFile = (Join-Path $PSScriptRoot '\main.bicep'),

    [ValidateNotNullOrEmpty()]
    [string] $ParametersFile = (Join-Path $PSScriptRoot '\template.parameters.json'),

    [ValidateNotNullOrEmpty()]
    [string] $Location
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
    throw 'Azure CLI is required. Install it and run az login before deploying.'
}

$TemplateFile = (Resolve-Path -LiteralPath $TemplateFile).Path
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
$parameterDocument = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json
$parameterValues = $parameterDocument.parameters
$locationProperty = $parameterValues.PSObject.Properties['location']
if (-not $Location -and $null -ne $locationProperty) {
    $Location = $locationProperty.Value.value
}

# Explicit subscription arguments avoid changing the user's default Azure subscription.
Invoke-AzureCli -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId, '--output', 'none'
) | Out-Null
Invoke-AzureCli -Arguments @('bicep', 'build', '--file', $TemplateFile, '--stdout') | Out-Null

$providersReady = $true
foreach ($provider in @('Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.OperationalInsights')) {
    $state = Invoke-AzureCli -Arguments @(
        'provider', 'show', '--namespace', $provider, '--subscription', $SubscriptionId,
        '--query', 'registrationState', '--output', 'tsv'
    )
    if ($state -ne 'Registered') {
        if ($PSCmdlet.ShouldProcess("$SubscriptionId/$provider", 'Register Azure resource provider')) {
            Invoke-AzureCli -Arguments @(
                'provider', 'register', '--namespace', $provider,
                '--subscription', $SubscriptionId, '--wait', '--output', 'none'
            ) | Out-Null
        }
        else {
            $providersReady = $false
        }
    }
}

$groupExists = Invoke-AzureCli -Arguments @(
    'group', 'exists', '--name', $ResourceGroupName,
    '--subscription', $SubscriptionId, '--output', 'tsv'
)
if ($groupExists -notin @('true', 'false')) {
    throw "Unexpected resource group existence response: $groupExists"
}
if ($groupExists -eq 'false') {
    if ([string]::IsNullOrWhiteSpace($Location)) {
        throw 'A location is required to create the resource group. Set location in the parameter file or pass -Location.'
    }
    if ($PSCmdlet.ShouldProcess("$SubscriptionId/$ResourceGroupName", "Create resource group in $Location")) {
        Invoke-AzureCli -Arguments @(
            'group', 'create', '--name', $ResourceGroupName, '--location', $Location,
            '--subscription', $SubscriptionId, '--output', 'none'
        ) | Out-Null
    }
    else {
        if ($WhatIfPreference) {
            Write-Warning 'Azure deployment preview requires an existing resource group. No Azure changes were made.'
            $null = $PSCmdlet.ShouldProcess("$ResourceGroupName/$DeploymentName", 'Deploy Bicep template')
            return
        }
        throw 'Resource group creation was declined; deployment cannot continue.'
    }
}

if (-not $providersReady) {
    if ($WhatIfPreference) {
        Write-Warning 'Azure deployment preview requires registered resource providers. No Azure changes were made.'
        $null = $PSCmdlet.ShouldProcess("$ResourceGroupName/$DeploymentName", 'Deploy Bicep template')
        return
    }
    throw 'Required provider registration was declined; deployment cannot continue.'
}

$deploymentArguments = @(
    'deployment', 'group', 'create', '--name', $DeploymentName,
    '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId,
    '--template-file', $TemplateFile, '--parameters', "@$ParametersFile"
)
if ($PSBoundParameters.ContainsKey('Location')) {
    $deploymentArguments += "location=$Location"
}

if ($WhatIfPreference) {
    $deploymentArguments[2] = 'what-if'
    Invoke-AzureCli -Arguments $deploymentArguments
}
elseif ($PSCmdlet.ShouldProcess("$ResourceGroupName/$DeploymentName", 'Deploy Bicep template')) {
    Invoke-AzureCli -Arguments ($deploymentArguments + @('--query', 'properties.outputs', '--output', 'json'))
}
