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

To validate the staged infrastructure and deployment helper, with Azure CLI
and Bicep installed, run:

```powershell
powershell -NoProfile -File .\tests\Deploy.Tests.ps1
```

These tests compile Bicep and mock Azure operations; they do not deploy resources.

## Run locally

From the repository root, with Docker running:

```sh
docker build --tag hello-world .
docker run --rm --publish 127.0.0.1:8080:80 hello-world
```

Open [http://localhost:8080](http://localhost:8080). Stop the container with
Ctrl+C.

## Set up Azure deployment

Complete steps 1-7 in order for a **new deployment**. You will create the Azure
infrastructure, **stop to manually upload an image to ACR**, then deploy the
Container App and configure GitHub for subsequent releases. Step 3 contains
these three separate phases. These instructions target Azure Public Cloud.

### 1. Check tools and permissions

- Install the [Azure CLI for Windows](https://learn.microsoft.com/cli/azure/install-azure-cli-windows),
  then open a new PowerShell terminal in VS Code.
- Open this repository's root folder in that terminal. For this checkout:

  ```powershell
  Set-Location D:\CICDPipelineSample
  az version
  ```

  `az version` should print version information. If `az` is not recognized,
  finish the installation and reopen the terminal.
- Have an Azure subscription and permission to create a dedicated resource
  group and register resource providers. Your signed-in account also needs
  **Contributor** plus **Role Based Access Control Administrator** on the
  resource group, or **Owner**, to deploy resources and assign roles.
  In the [Azure portal](https://portal.azure.com), open **Subscriptions**,
  select your subscription, and use **Access control (IAM) → View my access**
  to check your access. For an existing group, check its IAM page too.
  If access is missing, ask a subscription administrator to create the group,
  register the providers, and grant the required roles on that group.
- You need permission to register Microsoft Entra applications. If your
  organization's policy blocks app registration, ask your Entra administrator
  to complete steps 4-5 and provide the client ID and service principal object ID.
- You need GitHub repository access that allows managing Actions variables
  and running workflows. For a fork, enable Actions on its **Actions** tab.

Install [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)
and Node.js 24 for the manual initial image build in step 3. Start Docker
Desktop and use Linux containers. GitHub-hosted runners handle subsequent
builds and tests.

### 2. Sign in and select your subscription

Keep the **same PowerShell terminal** open for the remaining steps; later
commands reuse variables from earlier steps. Run each command separately,
check for errors, and stop if a command fails.

```powershell
az login
az account list --query "[].{Name:name,SubscriptionId:id,TenantId:tenantId}" --output table
```

Complete the browser sign-in. Copy the subscription ID from the row you want,
then replace the placeholder below. If you use a fork, change `$repository`
to its exact `OWNER/REPOSITORY` value. Choose a dedicated resource group because
cleanup deletes everything in it.

```powershell
$subscriptionId = "<subscription-id>"
$resourceGroup = "rg-hello-world"
$deploymentName = "hello-world-infra"
$location = "eastus"
$repository = "SteveCInVA/CICDPipelineSample"

az account set --subscription $subscriptionId
az account show --query "{Name:name,SubscriptionId:id,TenantId:tenantId}" --output table
```

**Check:** the final command must show the intended subscription and tenant.
All subsequent Azure CLI commands in this walkthrough use that subscription.

### 3. Provision infrastructure, upload the image, then deploy the app

#### Phase A: infrastructure only

[infra/Deploy.ps1](infra/Deploy.ps1) registers providers, creates the resource
group if needed, and deploys [infra/main.bicep](infra/main.bicep).
It requires PowerShell 5.1+ and uses
[infra/template.parameters.json](infra/template.parameters.json).
Preview and then run the infrastructure stage:

```powershell
.\infra\Deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -DeploymentName $deploymentName -Location $location -Stage Infrastructure -WhatIf
.\infra\Deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -DeploymentName $deploymentName -Location $location -Stage Infrastructure
```

Provider registration and deployment can take several minutes. If Azure CLI
asks to install Bicep, allow it; if it reports Bicep is missing, run
`az bicep install` and retry the deployment.

**Check:** confirm that deployment succeeded, then capture the generated names:

```powershell
az deployment group show --name $deploymentName --resource-group $resourceGroup --query properties.provisioningState --output tsv
$outputsJson = az deployment group show --name $deploymentName --resource-group $resourceGroup --query properties.outputs --output json
if ($LASTEXITCODE -ne 0) { throw "Could not read deployment outputs." }
$outputs = $outputsJson | ConvertFrom-Json
$githubVariables = $outputs.githubVariables.value
$containerApp = $githubVariables.AZURE_CONTAINER_APP
$registryName = $githubVariables.ACR_NAME
$loginServer = $githubVariables.ACR_LOGIN_SERVER
$outputs.applicationDeployed.value
$outputs.containerAppEnvironmentName.value
```

The state must be `Succeeded` and `applicationDeployed` must be `false`.
**Stop here.** There is no Container App or application URL yet on a new
deployment; `applicationUrl` is empty. `AZURE_CONTAINER_APP` is the reserved
name for the later stage, not evidence that the app exists.

This stage creates:

- A Basic Azure Container Registry (ACR) in **RBAC Registry Permissions**
  mode, with admin credentials off and ARM audience tokens enabled.
- A Consumption Container Apps environment and a Log Analytics workspace
  with 30-day retention.
- A user-assigned managed identity named `<container-app-name>-pull` with
  `AcrPull` on ACR. This identity exists **before** the app, so its private
  image can be pulled on the app's first deployment.

ACR and log ingestion incur charges even when the app scales to zero. The
registry is publicly reachable for GitHub-hosted runners but requires
authentication.

#### Phase B: manually upload the initial image

The account uploading the image needs **AcrPush** on the registry. Resource
management roles such as Contributor do not by themselves grant image push
access. For the interactive Azure account used in step 2, an account with role
assignment permissions can grant that access:

```powershell
$registryId = az acr show --name $registryName --resource-group $resourceGroup --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not find the registry." }
$uploaderId = az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not find the signed-in user. Ask an administrator to grant AcrPush to your uploading identity." }
az role assignment create --assignee-object-id $uploaderId --assignee-principal-type User --role AcrPush --scope $registryId
```

Skip the grant if the uploader already has AcrPush at this scope or an inherited
scope. Allow several minutes for both the uploader's AcrPush and the managed
identity's AcrPull to propagate. Do not enable ACR admin credentials.

From the repository root, test and build this application's Linux image, then
manually push it:

```powershell
$image = "$loginServer/hello-world:initial"
npm test
docker build --platform linux/amd64 --tag $image .
az acr login --name $registryName
docker push $image
az acr repository show --name $registryName --image "hello-world:initial" --output json
```

Run each command separately and stop on any failure. **Check:** the last
command must return the uploaded image's metadata. If you upload using a
different process, set `$image` to that exact ACR image, including its tag
or `@sha256:<digest>`. Do not continue with an image that has not been uploaded.

#### Phase C: deploy the Container App

Use the **same resource group, deployment base name, location, and parameter
file** as Phase A. The application stage requires an explicit image (via
`-ContainerImage` or the parameter file) and checks that it exists in the
provisioned registry before submitting the deployment:

```powershell
.\infra\Deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -DeploymentName $deploymentName -Location $location -Stage Application -ContainerImage $image -WhatIf
.\infra\Deploy.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -DeploymentName $deploymentName -Location $location -Stage Application -ContainerImage $image
```

The helper records this deployment as `<deployment-base-name>-app`, keeping
the infrastructure deployment's outputs available even if app creation fails.
It uses incremental mode: running Infrastructure again does not delete an
existing app. **Never use complete deployment mode** with the staged template.

**Check:** retrieve the application-stage outputs and open its URL:

```powershell
$applicationDeploymentName = "$deploymentName-app"
az deployment group show --name $applicationDeploymentName --resource-group $resourceGroup --query properties.provisioningState --output tsv
az deployment group show --name $applicationDeploymentName --resource-group $resourceGroup --query properties.outputs.applicationUrl.value --output tsv
```

The state must be `Succeeded`. The HTTPS URL should serve the **Local Clock**
immediately, with no public starter image. The app uses the pre-created
user-assigned identity for registry pulls and retains a system-assigned
identity for compatibility. Public ingress uses port **80**, single revision
mode, and zero to two replicas. If image pull is denied, confirm the image
exists and allow AcrPull propagation before retrying Phase C.

### 4. Create an identity for GitHub Actions

This is separate from the Container App's managed identities.
The user-assigned identity pulls images; GitHub needs to push images and update the app.
The Bicep template does not create this Entra registration.

Run these commands **once** to create an app registration and its service
principal, without a password or client secret:

```powershell
$clientId = az ad app create --display-name "hello-world-github-actions" --query appId --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not create the app registration." }
$principalId = az ad sp create --id $clientId --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not create the service principal." }

"AZURE_CLIENT_ID = $clientId"
"Service principal object ID = $principalId"
```

Save both printed IDs. They are identifiers, not secrets:

| ID | Where it is used |
| --- | --- |
| Application (client) ID (`$clientId`) | GitHub variable `AZURE_CLIENT_ID` and federated credential configuration |
| Service principal object ID (`$principalId`) | Azure role assignments; **not** the app registration's object ID |

If you already created the registration, do not create a duplicate. Find it in
**Azure portal → Microsoft Entra ID → App registrations → All applications**,
open it, and copy **Application (client) ID** from **Overview**. Recover the
variables in your terminal with:

```powershell
$clientId = "<existing-application-client-id>"
$principalId = az ad sp show --id $clientId --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not find the existing service principal." }
```

If that registration has no service principal yet, create it using the
`az ad sp create` command above.

### 5. Allow this repository's main branch to sign in and deploy

First, configure
[OpenID Connect (OIDC)](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).
This lets GitHub exchange a short-lived token for Azure access instead of
storing a client secret.

The following creates a temporary JSON file containing the trust settings,
adds the federated credential to the registration, and removes the file:

```powershell
$credentialFile = Join-Path $env:TEMP "hello-world-github-main-$clientId.json"
@{
    name = "github-main"
    issuer = "https://token.actions.githubusercontent.com"
    subject = "repo:${repository}:ref:refs/heads/main"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json | Set-Content -LiteralPath $credentialFile -Encoding ascii

az ad app federated-credential create --id $clientId --parameters $credentialFile
if ($LASTEXITCODE -ne 0) { throw "Could not create the federated credential. Check the error before continuing." }
Remove-Item -LiteralPath $credentialFile
az ad app federated-credential list --id $clientId --output json
```

**Check:** the list must contain `github-main` with the exact issuer, audience,
and subject above. For this repository the subject is
`repo:SteveCInVA/CICDPipelineSample:ref:refs/heads/main`. For a fork it must name
the fork, not the original repository. If `github-main` already exists, inspect
it rather than creating it again. This trust is for the `main` branch, not
pull requests or a GitHub environment.

Next, redeploy the template with the service principal object ID. It grants
**AcrPush** and **Reader** on the registry and **Contributor** on the Container
App, using repeatable role assignment names. These scopes do not grant it
Contributor across the whole subscription or resource group. Read and pass the
current image so this command also preserves an already-deployed application.

```powershell
$currentImage = az containerapp show --name $containerApp --resource-group $resourceGroup --query "properties.template.containers[0].image" --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentImage)) { throw "Could not read the current application image." }
az deployment group create --name $applicationDeploymentName --resource-group $resourceGroup --template-file .\infra\main.bicep --mode Incremental --parameters deployContainerApp=true "containerImage=$currentImage" "githubActionsPrincipalId=$principalId" "location=$location"

$registryId = az acr show --name $registryName --resource-group $resourceGroup --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not find the registry." }
$containerAppId = az containerapp show --name $containerApp --resource-group $resourceGroup --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw "Could not find the Container App." }

az role assignment list --scope $registryId --query "[?principalId=='$principalId'].{Role:roleDefinitionName,Scope:scope}" --output table
az role assignment list --scope $containerAppId --query "[?principalId=='$principalId'].{Role:roleDefinitionName,Scope:scope}" --output table
```

**Check:** the registry list must show `AcrPush` and `Reader`; the app list must
show `Contributor`. Allow several minutes for new assignments to propagate
before starting the workflow. If `az containerapp` is unavailable, run
`az extension add --name containerapp --upgrade`, then retry the command.

### 6. Add the GitHub repository variables

Print the values to copy:

```powershell
"AZURE_CLIENT_ID = $clientId"
$githubVariables | Format-List
```

In the **GitHub repository that will run the workflow**:

1. Open **Settings → Secrets and variables → Actions**.
2. Select the **Variables** tab, not **Secrets**.
3. Click **New repository variable**.
4. Enter a name from the table below and paste its corresponding value,
   without quotes or extra whitespace.
5. Click **Add variable** and repeat for all seven names.

| Variable | Value to copy |
| --- | --- |
| `AZURE_CLIENT_ID` | `$clientId`, the Entra application (client) ID |
| `AZURE_TENANT_ID` | `AZURE_TENANT_ID` from the printed deployment outputs |
| `AZURE_SUBSCRIPTION_ID` | `AZURE_SUBSCRIPTION_ID` from the printed deployment outputs |
| `AZURE_RESOURCE_GROUP` | `AZURE_RESOURCE_GROUP` from the printed deployment outputs |
| `AZURE_CONTAINER_APP` | `AZURE_CONTAINER_APP` from the printed deployment outputs |
| `ACR_NAME` | `ACR_NAME` from the printed deployment outputs |
| `ACR_LOGIN_SERVER` | `ACR_LOGIN_SERVER` from the printed deployment outputs, without `https://` |

**Check:** all seven names appear under **Repository variables**. The workflow
reads `vars`, so adding these only as secrets or environment variables will
not configure it. No Azure client secret is needed.

### 7. Run and verify the first CI/CD release

The [Container CI/CD workflow](.github/workflows/ci-cd.yml) runs on pushes to
`main` and pull requests targeting `main`. There is no manual **Run workflow**
button because it does not define `workflow_dispatch`.

1. Push a change to `main`, or merge an approved pull request into `main`,
   using your normal repository process. Pull request runs test the image
   but do **not** deploy it.
2. Open **GitHub → Actions → Container CI/CD** and select the run for that
   push to `main`.
3. Wait for **Test, build, and smoke-test**, then **Deploy to Azure Container
   Apps**, to succeed. CI saves the smoke-tested image as an artifact; the
   deploy job loads that exact image, pushes it to ACR, and updates the app.
4. Open the HTTPS URL printed in step 3 Phase C, or find it in **Azure portal →
   Resource groups → your resource group → your Container App → Overview →
   Application URL**.
5. Confirm the page says **Local Clock**, shows your browser's local time,
   and updates every second. A first request can take longer after scaling
   to zero; refresh if needed.

If a previous push-to-`main` run failed only because setup was incomplete,
open that run and choose **Re-run failed jobs** after completing setup.
For a new deployment without an application change, you can instead push an
empty commit, if your repository permits direct pushes:

```powershell
git switch main
git pull --ff-only
git commit --allow-empty -m "Trigger initial Azure deployment"
git push origin main
```

Do this only with a clean working tree and after verifying that `origin` is
the repository configured in step 2. For protected branches, use the normal
pull request process instead.

### Troubleshooting setup

| Symptom | What to check or do |
| --- | --- |
| Resource deployment or role assignment reports `AuthorizationFailed` | Check the signed-in subscription in step 2 and your Azure IAM roles in step 1. Role assignment permission is separate from Contributor. |
| `az ad app create` reports insufficient privileges | Ask your Entra administrator to create the registration and service principal or grant permission to register apps. |
| Azure Login reports no matching federated identity credential | Compare the credential's repository, `main` branch subject, issuer, and audience with step 5. Confirm `AZURE_CLIENT_ID` is the application client ID, not either object ID. |
| Azure Login reports a missing client, tenant, or subscription ID | Confirm the exact variable names under GitHub **Repository variables**, not Secrets. |
| ACR push or Container App update is denied | Check the three workflow role assignments in step 5, wait for propagation, then re-run the failed jobs. Do not enable the ACR admin account as a workaround. |
| Deploy job is skipped | Use a push to `main`; pull request runs intentionally build/test only. |
| Application stage rejects a missing image or registry mismatch | Complete step 3 Phase B and supply the exact tagged image from the registry created in Phase A. The helper does not build or push images. |
| App deployment reports an image pull error | Confirm the image exists and the `<container-app-name>-pull` identity has AcrPull; allow role propagation and retry Phase C. |
| Infrastructure stage has no application URL | Expected on a new deployment: complete the manual upload and Application stage. Do not start CI/CD until the app exists. |

### Optional: parameter file or deployment helper

The walkthrough above uses the template's generated resource names. Parameters
are `location`, `containerAppName`, `registryName`, `deployContainerApp`,
`containerImage`, and `githubActionsPrincipalId`. Default app and registry names are generated
deterministically from the resource group ID.

The helper accepts `-TemplateFile` and `-ParametersFile`; paths default to files
beside the script. `-Stage Infrastructure` is the default and overrides any
`deployContainerApp` value in the file to `false`. `-Stage Application`
overrides it to `true`. `-ContainerImage` overrides the file's `containerImage`.
The parameter file defaults to `eastus` and infrastructure only; add
`containerImage` with the uploaded image when resuming without that CLI argument.
Its empty `githubActionsPrincipalId` skips workflow roles. Set it to the
service principal object ID from step 4 to manage those roles in Bicep.

To use Azure CLI directly instead of the helper, register all four providers
and create the group, then deploy infrastructure only:

```powershell
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.ManagedIdentity --wait
az group create --name $resourceGroup --location $location
az deployment group create --name $deploymentName --resource-group $resourceGroup --template-file .\infra\main.bicep --mode Incremental --parameters "@infra\template.parameters.json" deployContainerApp=false "location=$location"
```

Capture the Phase A outputs, manually upload and verify the image as in
Phase B, then deploy the app:

```powershell
az deployment group create --name "$deploymentName-app" --resource-group $resourceGroup --template-file .\infra\main.bicep --mode Incremental --parameters "@infra\template.parameters.json" deployContainerApp=true "containerImage=$image" "location=$location"
```

Direct CLI deployments do not perform the helper's image-existence preflight;
you must verify the image manually. `containerImage` defaults to the generated
registry's `hello-world:initial` tag, but Bicep does **not** create that image.
Always pass the exact uploaded image explicitly for application deployments.

`-WhatIf` makes no Azure changes: the helper previews the deployment if
prerequisites exist, or reports prerequisite operations without creating them.
Application previews also check that the image exists. Normal execution
prints deployment outputs and stops on CLI errors. The script always uses the
specified subscription without changing your Azure CLI default.

**When redeploying the app after CI/CD has published an update**, preserve the
current image instead of restoring the initial tag:

```powershell
$currentImage = az containerapp show --name $containerApp --resource-group $resourceGroup --query "properties.template.containers[0].image" --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentImage)) { throw "Could not read the current application image." }
az deployment group create --name "$deploymentName-app" --resource-group $resourceGroup --template-file .\infra\main.bicep --mode Incremental --parameters deployContainerApp=true "containerImage=$currentImage" "githubActionsPrincipalId=$principalId" "location=$location"
```

For parameter-file or helper-script deployments, set that file's
`containerImage.value` to the retrieved image and
`githubActionsPrincipalId.value` to the service principal object ID before
running the Application stage. Reuse any custom app and registry names from
Phase A for every later deployment. Existing deployments using a system-assigned
pull identity can adopt the new process without deletion: run Infrastructure
to create the user-assigned identity, then Application with the current image
to switch registry authentication.

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
