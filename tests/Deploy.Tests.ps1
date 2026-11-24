#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$deployScript = Join-Path $root 'infra\Deploy.ps1'
$templateFile = Join-Path $root 'infra\main.bicep'
$parametersFile = Join-Path $root 'infra\template.parameters.json'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Fails {
    param([scriptblock] $Action, [string] $ExpectedMessage)
    try {
        & $Action | Out-Null
    }
    catch {
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") $_.Exception.Message
        return
    }
    throw "Expected failure: $ExpectedMessage"
}

$compiledJson = & az bicep build --file $templateFile --stdout
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
$template = $compiledJson | ConvertFrom-Json
$app = @($template.resources | Where-Object type -eq 'Microsoft.App/containerApps')[0]
$pullRole = @($template.resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
    $_.properties.roleDefinitionId -eq "[variables('acrPullRoleId')]"
})[0]
$appRole = @($template.resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
    $_.properties.roleDefinitionId -eq "[variables('contributorRoleId')]"
})[0]
Assert-True ($app.condition -eq "[parameters('deployContainerApp')]") 'The app must be conditional.'
Assert-True ($appRole.condition -match "parameters\('deployContainerApp'\)") 'App-scoped roles must be conditional.'
Assert-True (($pullRole.dependsOn -join ' ') -notmatch 'Microsoft.App/containerApps') 'Pull permissions must exist without an app.'
Assert-True (($app.dependsOn -join ' ') -match 'Microsoft.Authorization/roleAssignments') 'The app must wait for its pull role.'
Assert-True ($app.properties.configuration.registries[0].identity -match 'Microsoft.ManagedIdentity/userAssignedIdentities') 'Registry pulls must use the pre-created identity.'
Assert-True ($template.outputs.applicationUrl.value -match "^\[if\(parameters\('deployContainerApp'\)") 'Infrastructure outputs must not evaluate the absent app.'
Write-Host 'PASS: compiled template stages the app behind pre-created pull permissions.'

$script:calls = New-Object 'System.Collections.Generic.List[object]'
$global:DeploymentTestCalls = $script:calls
$global:DeploymentTestManifestMissing = $false
$global:DeploymentTestCompiledJson = $compiledJson
$mockOutputs = @{
    githubVariables = @{
        value = @{
            ACR_NAME = 'testregistry'
            ACR_LOGIN_SERVER = 'testregistry.azurecr.io'
        }
    }
} | ConvertTo-Json -Depth 4
$global:DeploymentTestOutputs = $mockOutputs

function global:az {
    $arguments = @($args)
    $global:DeploymentTestCalls.Add($arguments)
    $global:LASTEXITCODE = 0
    switch (($arguments | Select-Object -First 3) -join ' ') {
        'account show --subscription' { return }
        'bicep build --file' { return $global:DeploymentTestCompiledJson }
        'provider show --namespace' { return 'Registered' }
        'group exists --name' { return 'true' }
        'deployment group show' { return $global:DeploymentTestOutputs }
        'acr repository show' {
            if ($global:DeploymentTestManifestMissing) { $global:LASTEXITCODE = 1 }
            return
        }
        'deployment group create' { return $global:DeploymentTestOutputs }
        'deployment group what-if' { return 'Preview only' }
        default { throw "Unexpected Azure CLI call: $($arguments -join ' ')" }
    }
}

function Get-DeploymentCall {
    foreach ($call in $script:calls) {
        if (($call | Select-Object -First 3) -join ' ' -eq 'deployment group create') {
            return ,$call
        }
    }
    throw 'No deployment was submitted.'
}

$fixtureFile = [IO.Path]::GetTempFileName()
try {
    @{
        parameters = @{
            location = @{ value = 'eastus' }
            deployContainerApp = @{ value = $true }
            containerImage = @{ value = 'testregistry.azurecr.io/hello-world:existing' }
        }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fixtureFile -Encoding ascii
    $common = @{
        SubscriptionId = 'test-subscription'
        TemplateFile = $templateFile
        ParametersFile = $parametersFile
        Confirm = $false
    }
    $fixtureCommon = $common.Clone()
    $fixtureCommon.ParametersFile = $fixtureFile

    & $deployScript @fixtureCommon | Out-Null
    $call = Get-DeploymentCall
    Assert-True ($call -ccontains 'deployContainerApp=false') 'Infrastructure must override an enabled parameter-file app with a JSON boolean.'
    Assert-True (($call -join ' ') -match '--mode Incremental') 'Staging must never use complete mode.'
    Assert-True (-not (($script:calls | ForEach-Object { $_ -join ' ' }) -match '^acr repository show')) 'Infrastructure must not require an image.'
    Write-Host 'PASS: infrastructure stops without an image even when the file enables the app.'

    $script:calls.Clear()
    Assert-Fails { & $deployScript @common -Stage Application } 'Application stage requires'
    Assert-True ($script:calls.Count -eq 0) 'Missing image input must fail before Azure calls.'

    foreach ($image in @('otherregistry.azurecr.io/hello-world:initial', 'testregistry.azurecr.io/hello-world')) {
        $script:calls.Clear()
        Assert-Fails { & $deployScript @common -Stage Application -ContainerImage $image } 'ContainerImage must'
        Assert-True (-not (($script:calls | ForEach-Object { $_ -join ' ' }) -match '^deployment group create')) 'Invalid images must not submit deployments.'
    }
    Write-Host 'PASS: missing, foreign-registry, and untagged image inputs are rejected.'

    $script:calls.Clear()
    $global:DeploymentTestManifestMissing = $true
    Assert-Fails { & $deployScript @common -Stage Application -ContainerImage 'testregistry.azurecr.io/hello-world:initial' } 'Azure CLI failed'
    Assert-True (-not (($script:calls | ForEach-Object { $_ -join ' ' }) -match '^deployment group create')) 'An absent manifest must prevent app deployment.'
    $global:DeploymentTestManifestMissing = $false
    Write-Host 'PASS: an image missing from ACR prevents app deployment.'

    $script:calls.Clear()
    & $deployScript @common -Stage Application -ContainerImage 'testregistry.azurecr.io/hello-world:initial' | Out-Null
    $call = Get-DeploymentCall
    Assert-True ($call -ccontains 'deployContainerApp=true') 'Application stage must enable the app with a JSON boolean.'
    Assert-True ($call -contains 'containerImage=testregistry.azurecr.io/hello-world:initial') 'Application must use the verified image.'
    Assert-True ($call -contains 'hello-world-infra-app') 'Application must preserve the infrastructure deployment record.'
    $commands = @($script:calls | ForEach-Object { $_ -join ' ' })
    $manifestIndex = -1
    $deploymentIndex = -1
    for ($index = 0; $index -lt $commands.Count; $index++) {
        if ($commands[$index] -match '^acr repository show') { $manifestIndex = $index }
        if ($commands[$index] -match '^deployment group create') { $deploymentIndex = $index }
    }
    Assert-True ($manifestIndex -ge 0 -and $manifestIndex -lt $deploymentIndex) 'Image verification must precede deployment.'
    Write-Host 'PASS: application verifies the image before resuming in a separate deployment.'

    $script:calls.Clear()
    & $deployScript @fixtureCommon -Stage Application -WhatIf | Out-Null
    $commands = @($script:calls | ForEach-Object { $_ -join ' ' })
    Assert-True (-not ($commands -match '^deployment group create')) 'WhatIf must not submit a deployment.'
    Assert-True ([bool]($commands -match '^deployment group what-if.*containerImage=testregistry.azurecr.io/hello-world:existing')) 'Preview must use the image from the parameter file.'
    Write-Host 'PASS: application preview verifies the parameter-file image without writes.'
}
finally {
    Remove-Item -LiteralPath $fixtureFile
    Remove-Item Function:\az
    Remove-Variable -Scope Global -Name DeploymentTestCalls, DeploymentTestManifestMissing, DeploymentTestCompiledJson, DeploymentTestOutputs
}
