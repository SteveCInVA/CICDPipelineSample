targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Container App name. Use lowercase letters, numbers, and hyphens; start with a letter, end with a letter or number, and do not use consecutive hyphens.')
@minLength(2)
@maxLength(32)
param containerAppName string = 'hello-world-${uniqueString(resourceGroup().id)}'

@description('Globally unique registry name containing only letters and numbers.')
@minLength(5)
@maxLength(50)
param registryName string = 'acr${uniqueString(resourceGroup().id)}'

@description('Deploy the Container App only after the image has been manually uploaded to ACR. False provisions infrastructure only; use incremental deployment mode.')
param deployContainerApp bool = false

@description('Existing ACR image with tag or digest. Upload it before enabling deployContainerApp. On subsequent deployments, pass the current application image.')
@minLength(1)
param containerImage string = '${registryName}.azurecr.io/hello-world:initial'

@description('Optional object ID of the existing GitHub Actions service principal, NOT its application/client ID. Empty skips workflow role assignments.')
param githubActionsPrincipalId string = ''

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var acrPushRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    roleAssignmentMode: 'LegacyRegistryPermissions'
    policies: {
      azureADAuthenticationAsArmPolicy: {
        status: 'enabled'
      }
    }
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${containerAppName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: '${containerAppName}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${containerAppName}-pull'
  location: location
}

resource appAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, pullIdentity.id, acrPullRoleId)
  scope: registry
  properties: {
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource app 'Microsoft.App/containerApps@2025-01-01' = if (deployContainerApp) {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }
  dependsOn: [
    appAcrPull
  ]
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registry.properties.loginServer
          identity: pullIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'hello-world'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

resource githubAcrPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(githubActionsPrincipalId)) {
  name: guid(registry.id, githubActionsPrincipalId, acrPushRoleId)
  scope: registry
  properties: {
    principalId: githubActionsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPushRoleId
  }
}

resource githubAcrReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(githubActionsPrincipalId)) {
  name: guid(registry.id, githubActionsPrincipalId, readerRoleId)
  scope: registry
  properties: {
    principalId: githubActionsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
}

resource githubAppContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployContainerApp && !empty(githubActionsPrincipalId)) {
  name: guid(app.id, githubActionsPrincipalId, contributorRoleId)
  scope: app
  properties: {
    principalId: githubActionsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
  }
}

output applicationDeployed bool = deployContainerApp
output applicationUrl string = deployContainerApp ? 'https://${app!.properties.configuration.ingress.fqdn}' : ''
output containerAppEnvironmentName string = environment.name
output imagePullIdentityId string = pullIdentity.id
output githubVariables object = {
  AZURE_TENANT_ID: tenant().tenantId
  AZURE_SUBSCRIPTION_ID: subscription().subscriptionId
  AZURE_RESOURCE_GROUP: resourceGroup().name
  AZURE_CONTAINER_APP: containerAppName
  ACR_NAME: registry.name
  ACR_LOGIN_SERVER: registry.properties.loginServer
}
