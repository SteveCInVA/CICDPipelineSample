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

    [ValidateSet('Infrastructure', 'Application')]
    [string] $Stage = 'Infrastructure',

    [ValidateNotNullOrEmpty()]
    [string] $ContainerImage,

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

if ($Stage -eq 'Application') {
    $imageProperty = $parameterValues.PSObject.Properties['containerImage']
    if (-not $PSBoundParameters.ContainsKey('ContainerImage') -and $null -ne $imageProperty) {
        $ContainerImage = $imageProperty.Value.value
    }
    if ([string]::IsNullOrWhiteSpace($ContainerImage)) {
        throw 'Application stage requires -ContainerImage or containerImage in the parameter file. Upload the image to ACR first.'
    }
}
elseif ($PSBoundParameters.ContainsKey('ContainerImage')) {
    throw '-ContainerImage is only supported with -Stage Application.'
}

# Explicit subscription arguments avoid changing the user's default Azure subscription.
Invoke-AzureCli -Arguments @(
    'account', 'show', '--subscription', $SubscriptionId, '--output', 'none'
) | Out-Null
Invoke-AzureCli -Arguments @('bicep', 'build', '--file', $TemplateFile, '--stdout') | Out-Null

if ($Stage -eq 'Application') {
    $outputsJson = Invoke-AzureCli -Arguments @(
        'deployment', 'group', 'show', '--name', $DeploymentName,
        '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId,
        '--query', 'properties.outputs', '--output', 'json'
    )
    $outputs = $outputsJson | ConvertFrom-Json
    $registryName = $outputs.githubVariables.value.ACR_NAME
    $loginServer = $outputs.githubVariables.value.ACR_LOGIN_SERVER
    if ([string]::IsNullOrWhiteSpace($registryName) -or [string]::IsNullOrWhiteSpace($loginServer)) {
        throw 'Infrastructure deployment outputs must contain ACR_NAME and ACR_LOGIN_SERVER. Run -Stage Infrastructure first.'
    }
    $imagePrefix = "$loginServer/"
    if (-not $ContainerImage.StartsWith($imagePrefix, [StringComparison]::Ordinal)) {
        throw "ContainerImage must reference the provisioned registry: $loginServer"
    }
    $registryImage = $ContainerImage.Substring($imagePrefix.Length)
    if ($registryImage -notmatch '^[^@\s:]+(?::[^@\s:]+|@sha256:[0-9a-fA-F]{64})$') {
        throw 'ContainerImage must include an explicit image tag or sha256 digest.'
    }
    Invoke-AzureCli -Arguments @(
        'acr', 'repository', 'show', '--name', $registryName, '--image', $registryImage,
        '--subscription', $SubscriptionId, '--output', 'none'
    ) | Out-Null
}

$providersReady = $true
foreach ($provider in @('Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.OperationalInsights', 'Microsoft.ManagedIdentity')) {
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

$stageDeploymentName = $DeploymentName
$deployContainerAppValue = 'false'
if ($Stage -eq 'Application') {
    $stageDeploymentName = "$DeploymentName-app"
    $deployContainerAppValue = 'true'
}
$deploymentArguments = @(
    'deployment', 'group', 'create', '--name', $stageDeploymentName,
    '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId,
    '--template-file', $TemplateFile, '--mode', 'Incremental', '--parameters', "@$ParametersFile",
    "deployContainerApp=$deployContainerAppValue"
)
if ($Stage -eq 'Application') {
    $deploymentArguments += "containerImage=$ContainerImage"
}
if ($PSBoundParameters.ContainsKey('Location')) {
    $deploymentArguments += "location=$Location"
}

if ($WhatIfPreference) {
    $deploymentArguments[2] = 'what-if'
    Invoke-AzureCli -Arguments $deploymentArguments
}
elseif ($PSCmdlet.ShouldProcess("$ResourceGroupName/$stageDeploymentName", 'Deploy Bicep template')) {
    Invoke-AzureCli -Arguments ($deploymentArguments + @('--query', 'properties.outputs', '--output', 'json'))
    if ($Stage -eq 'Infrastructure') {
        Write-Host 'Infrastructure is ready. No Container App was deployed. Upload the image to ACR, allow AcrPull permissions to propagate, then run -Stage Application -ContainerImage <acr-image-with-tag-or-digest>.'
    }
}
