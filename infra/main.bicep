// =====================================================================
// tdd-multi-identity-acr-auth — azd entry point (subscription scope)
//
// Trainer Demo Deploy scenario. Reproduces Azure DevOps Docker-task
// Managed Service Identity auth failure when two or more user-assigned
// managed identities are attached to the build agent.
// Source: Case 2605130050002742 / IcM 813892533.
// =====================================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to name and tag all resources.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string = 'eastus2'

@description('Azure DevOps organization URL the self-hosted agent registers into, e.g. https://dev.azure.com/your-sandbox-org')
param adoOrgUrl string

@description('Azure DevOps agent pool name (create it as a self-hosted pool first).')
param adoAgentPool string = 'demodeploy-repro-pool'

@secure()
@description('Azure DevOps PAT with "Agent Pools (read & manage)". Used only to register the agent.')
param adoPat string

@secure()
@description('SSH public key for the agent VM.')
param adminSshPublicKey string

@description('Admin username for the agent VM.')
param adminUsername string = 'azureuser'

@description('VM size. Choose a SKU permitted by your subscription/SFI policy.')
param vmSize string = 'Standard_D2s_v5'

@description('CIDR allowed to SSH to the agent VM. Lock to your IP (e.g. 203.0.113.5/32). "*" is open and not recommended.')
param allowedSshSourceCidr string = '*'

var tags = {
  'azd-env-name': environmentName
  scenario: 'tdd-multi-identity-acr-auth'
}
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    adoOrgUrl: adoOrgUrl
    adoAgentPool: adoAgentPool
    adoPat: adoPat
    adminSshPublicKey: adminSshPublicKey
    adminUsername: adminUsername
    vmSize: vmSize
    allowedSshSourceCidr: allowedSshSourceCidr
  }
}

// azd captures these into the environment (.azure/<env>/.env)
output AZURE_LOCATION string = location
output ACR_NAME string = resources.outputs.acrName
output ACR_LOGIN_SERVER string = resources.outputs.acrLoginServer
output IDENTITY_A_CLIENT_ID string = resources.outputs.identityAClientId
output IDENTITY_B_CLIENT_ID string = resources.outputs.identityBClientId
output AGENT_PUBLIC_IP string = resources.outputs.agentPublicIp
output SSH_COMMAND string = resources.outputs.sshCommand
