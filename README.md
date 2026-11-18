# CICDPipelineSample

A static **Hello World!** page served by NGINX and deployed to Azure Container
Apps with GitHub Actions.

## Run locally

From the repository root, with Docker running:

```sh
docker build --tag hello-world .
docker run --rm --publish 127.0.0.1:8080:80 hello-world
```

Open [http://localhost:8080](http://localhost:8080). Stop the container with
Ctrl+C.

## Set up Azure deployment

1. Create an Azure Container Registry (ACR) in **RBAC Registry Permissions**
   mode so the `AcrPush` and `AcrPull` roles apply. The registry must be reachable
   by GitHub-hosted runners and the Container App. Leave admin credentials off.
2. In the same subscription, create an Azure Container Apps environment and a
   Container App in single revision mode. Use a public starter image such as
   `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest`, and set ingress
   to **external** with target port **80**. Enable the app's system-assigned
   managed identity, grant it `AcrPull` on the registry, and configure the app
   to use that identity for the registry. Ensure the registry allows ARM
   audience tokens for managed identity pulls. For example, after assigning the
   role, run:

   ```sh
   az acr config authentication-as-arm update --registry "$ACR_NAME" --status enabled
   az containerapp registry set --resource-group "$AZURE_RESOURCE_GROUP" \
     --name "$AZURE_CONTAINER_APP" --server "$ACR_LOGIN_SERVER" --identity system
   ```

3. Create a Microsoft Entra app registration for GitHub Actions and add a
   [federated credential](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
   for this repository's `main` branch. The subject is
   `repo:SteveCInVA/CICDPipelineSample:ref:refs/heads/main` (substitute your
   owner/repository if you fork it), the issuer is
   `https://token.actions.githubusercontent.com`, and the audience is
   `api://AzureADTokenExchange`. Grant its service principal `AcrPush` and
   `Reader` on the registry (to push images and resolve the login server),
   and `Contributor` scoped to the Container App.
4. In GitHub, go to **Settings → Secrets and variables → Actions → Variables**
   and add these repository variables. No Azure client secret is needed.

   | Variable | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | Entra app registration's application (client) ID |
   | `AZURE_TENANT_ID` | Entra directory (tenant) ID |
   | `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
   | `AZURE_RESOURCE_GROUP` | Resource group that contains the Container App |
   | `AZURE_CONTAINER_APP` | Container App name |
   | `ACR_NAME` | Registry resource name |
   | `ACR_LOGIN_SERVER` | Registry login server from the ACR overview, without `https://` |

## Release a change

Pull requests targeting `main` build the container and check that `/` returns
the Hello World heading. A push to `main` runs the same check, pushes the tested
image to ACR, and updates the Container App to a new revision. After the deploy
job succeeds, open the app's **Application URL** in the Azure portal to confirm
that it serves the updated page.
