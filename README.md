# CICDPipelineSample

A simple **Local Clock** served by NGINX and deployed to Azure Container Apps
with GitHub Actions. It displays the browser's local time in 24-hour
`HH:MM:SS` format and updates every second. JavaScript is required.

The page calls `formatTime(date)` in [source/clock.js](source/clock.js) to format
the current time with zero-padded hours, minutes, and seconds.

## Run tests

With Node.js 24 installed, run `npm test` from the repository root.
No dependency installation is needed. The tests cover zero-padding, midnight,
noon, the end of the day, and midnight rollover.

## Run locally

From the repository root, with Docker running:

```sh
docker build --tag hello-world .
docker run --rm --publish 127.0.0.1:8080:80 hello-world
```

Open [http://localhost:8080](http://localhost:8080). Stop the container with
Ctrl+C.

## Set up Azure deployment

1. Deploy [infra/main.bicep](infra/main.bicep) to a resource group using the
   Azure CLI. It creates a Basic Azure Container Registry (ACR) in **RBAC
   Registry Permissions** mode with admin credentials off and ARM audience
   tokens enabled, a Consumption Container Apps environment, a Log Analytics
   workspace with 30-day retention, and a Container App with a system-assigned
   identity and `AcrPull` on the registry. Public ingress uses HTTPS and target
   port **80**, with single revision mode and zero to two replicas.

   Run from the repository root in PowerShell (replace the subscription ID):

   ```powershell
   az login
   az account set --subscription "<subscription-id>"
   az provider register --namespace Microsoft.App --wait
   az provider register --namespace Microsoft.ContainerRegistry --wait
   az provider register --namespace Microsoft.OperationalInsights --wait
   az group create --name rg-hello-world --location eastus
   az deployment group create --name hello-world-infra --resource-group rg-hello-world --template-file .\infra\main.bicep
   ```

   Your deployment identity needs resource creation and role assignment
   permissions, such as **Contributor** plus **Role Based Access Control
   Administrator** on the resource group. The template deploys a public starter
   image, not this repository's page; CI/CD publishes the tested application
   image after the remaining setup. ACR and log ingestion incur charges even
   when the app scales to zero. The registry is publicly reachable to support
   GitHub-hosted runners, but requires authentication.

   Optional parameters include `location`, `containerAppName`, `registryName`,
   `containerImage`, and `githubActionsPrincipalId`. Defaults generate stable
   resource names from the resource group ID.

   To use [infra/template.paramaters.json](infra/template.paramaters.json),
   edit its values and deploy with:

   ```powershell
   az deployment group create --name hello-world-infra --resource-group rg-hello-world --template-file .\infra\main.bicep --parameters "@infra\template.paramaters.json"
   ```

   The parameter file keeps the generated app and registry names by omitting
   those overrides. Its empty `githubActionsPrincipalId` skips workflow role
   assignments; set it to the service principal object ID when available.
   Before redeploying an existing application, set `containerImage` to its
   current ACR image and tag to avoid restoring the starter image.

   Alternatively, [infra/Deploy.ps1](infra/Deploy.ps1) handles provider
   registration, resource group creation if needed, and deployment using the
   parameter file. Requires PowerShell 5.1+ and Azure CLI; run `az login` first.
   Paths default to files beside the script, regardless of your working directory.

   ```powershell
   .\infra\Deploy.ps1 -SubscriptionId "<subscription-id>" -WhatIf
   .\infra\Deploy.ps1 -SubscriptionId "<subscription-id>"
   ```

   `-WhatIf` makes no Azure changes. When the resource group exists and the
   providers are registered, it runs Azure deployment what-if to preview
   resource changes; otherwise it reports the prerequisite operations without
   creating them. Normal execution prints the deployment outputs. You can
   override `-ResourceGroupName`, `-DeploymentName`, `-TemplateFile`,
   `-ParametersFile`, or `-Location`; `-Location` also overrides the template's
   location. The script uses the specified subscription without changing your
   Azure CLI default, and stops on CLI errors.

2. Create a Microsoft Entra app registration for GitHub Actions and add a
   [federated credential](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
   for this repository's `main` branch. The subject is
   `repo:SteveCInVA/CICDPipelineSample:ref:refs/heads/main` (substitute your
   owner/repository if you fork it), the issuer is
   `https://token.actions.githubusercontent.com`, and the audience is
   `api://AzureADTokenExchange`. The template does not create the Entra app
   registration or federated credential. Grant its service principal `AcrPush`
   and `Reader` on the registry (to push images and resolve the login server),
   and `Contributor` scoped to the Container App. Alternatively, redeploy the
   template with its service principal **object ID**, not its client ID:

   ```powershell
   az deployment group create --name hello-world-infra --resource-group rg-hello-world --template-file .\infra\main.bicep --parameters githubActionsPrincipalId="<service-principal-object-id>"
   ```

   Allow time for role assignments to propagate before running CI/CD. For
   redeployments **after CI/CD has deployed the application**, also pass
   `containerImage="<current-acr-image-with-tag>"` to preserve the deployed image;
   omitting it restores the public starter. A first deployment must use a public
   image because the app's system-assigned identity does not yet exist.

3. In GitHub, go to **Settings → Secrets and variables → Actions → Variables**
   and add these repository variables. No Azure client secret is needed.
   Deployment output `githubVariables` supplies all values except
   `AZURE_CLIENT_ID`, which comes from your Entra app registration:

   ```powershell
   az deployment group show --name hello-world-infra --resource-group rg-hello-world --query properties.outputs --output json
   ```

   | Variable | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | Entra app registration's application (client) ID |
   | `AZURE_TENANT_ID` | Entra directory (tenant) ID |
   | `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
   | `AZURE_RESOURCE_GROUP` | Resource group that contains the Container App |
   | `AZURE_CONTAINER_APP` | Container App name |
   | `ACR_NAME` | Registry resource name |
   | `ACR_LOGIN_SERVER` | Registry login server from the ACR overview, without `https://` |

## Clean up Azure deployment

When the deployment is no longer needed, use [infra/Cleanup.ps1](infra/Cleanup.ps1).
Requires PowerShell 5.1+ and Azure CLI; run `az login` first.

```powershell
.\infra\Cleanup.ps1 -SubscriptionId "<subscription-id>" -WhatIf
.\infra\Cleanup.ps1 -SubscriptionId "<subscription-id>"
```

The script defaults to `rg-hello-world`; pass `-ResourceGroupName` to target a
different group. It prompts for confirmation before deleting the **entire
resource group and everything in it**, including any unrelated resources added
to the group, stored container images, and logs. Only use it with a dedicated
resource group. `-WhatIf` previews the deletion without making changes.

The script uses the specified subscription without changing your Azure CLI
default, waits for deletion to finish, and stops on CLI errors. An already
absent group is reported without error. It does not remove the separately
created Entra app registration, federated credential, or GitHub Actions
variables. Disable deployment workflows before cleanup to avoid failed or
concurrent deployments.

## Release a change

Pull requests targeting `main` run the clock function tests, build the container,
and check that `/` returns the Local Clock heading and `/clock.js` is served.
A push to `main` runs the same checks, pushes the tested
image to ACR, and updates the Container App to a new revision. After the deploy
job succeeds, open the app's **Application URL** in the Azure portal to confirm
that it serves the updated page.
