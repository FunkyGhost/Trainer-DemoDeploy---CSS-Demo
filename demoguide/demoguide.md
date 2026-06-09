# Demo guide — Multi-identity ACR auth failure on Azure Pipelines

**Scenario:** `tdd-multi-identity-acr-auth`
**Source case:** 2605130050002742 (IcM 813892533) · Azure DevOps Pipelines · Docker task 2.269.1
**Audience:** CSS engineers, support/readiness, anyone learning Managed Identity + ACR on Pipelines
**Duration:** ~10 minutes · **Deploy time:** ~10 minutes · **Cost:** ~$2–4/day

---

## The story

A customer's pipeline pushes a container image to Azure Container Registry using a **Docker
Registry service connection** configured for **Managed Service Identity (MSI)** authentication.
It worked perfectly with a single user-assigned managed identity on the build agent. The moment
a **second** user-assigned identity was added, the pipeline began failing on **every run** — yet
RBAC was correct and nothing else changed.

This demo reproduces that failure deterministically, then shows the fix — all inside one
environment that stands up from a single `azd up`.

## What gets deployed

| Resource | Role in the repro |
|---|---|
| VNet + subnet + NSG | Network for the agent (SSH locked to your CIDR) |
| Public IP + NIC | Reach the agent |
| **2× user-assigned managed identities** | **The trigger** — ambiguity when both are attached |
| Azure Container Registry (Basic) | Push target |
| AcrPull + AcrPush on **both** identities | Removes RBAC as a variable — failure is pure ambiguity |
| Ubuntu 22.04 self-hosted agent VM | Both identities attached; auto-registers to your pool |

## Prerequisites

- Azure subscription where you can create role assignments (Owner or User Access Administrator).
- A **sandbox** Azure DevOps org (never the customer's).
- An ADO **PAT** with *Agent Pools (read & manage)*.
- An SSH public key.
- `azd` and `az` CLIs installed and logged in.

## Setup

```bash
# 1. Create the self-hosted pool in your sandbox org first:
#    Org Settings > Agent pools > Add pool > Self-hosted > "demodeploy-repro-pool"

# 2. Configure the azd environment
azd init -t tdd-multi-identity-acr-auth        # or run from a clone of this repo
azd env set ADO_ORG_URL          https://dev.azure.com/<your-sandbox-org>
azd env set ADO_PAT              <your-PAT>
azd env set ADMIN_SSH_PUBLIC_KEY "$(cat ~/.ssh/id_rsa.pub)"
azd env set ALLOWED_SSH_CIDR     <your.ip.address>/32

# 3. Deploy the whole lab
azd up
```
Within ~2–3 minutes after deploy, the agent shows **online** in the pool. Note the azd outputs:
`ACR_NAME`, `ACR_LOGIN_SERVER`, `IDENTITY_A_CLIENT_ID`, `IDENTITY_B_CLIENT_ID`, `AGENT_PUBLIC_IP`.

## Live demo flow (~10 min)

| Time | Do this | Say this |
|---|---|---|
| 0–1 | Show the empty resource group / blank ADO project | "This lab is 8 moving parts — normally an hour of clicking." |
| 1–4 | `azd up` (or show a pre-run); agent appears **online** | "One command stood up the network, identities, registry, RBAC, and a registered agent." |
| 4–7 | Create the **`acr-msi-sc`** Docker Registry SC (ACR, Managed Identity), then run `src/azure-pipelines.yml` | "Two identities are attached. Watch the Docker task." → it fails with the customer's exact error |
| 7–9 | **Payoff:** either detach `id-b-*` (Portal → VM → Identity) **or** switch to the pinned-identity script step in the pipeline | "Pin one identity by client-id and it's green — repro and fix in the same environment." |
| 9–10 | Wrap | "This whole scenario could be generated from a prompt and contributed back to the catalog." |

## The exact failure to point at

```
##[debug][GET]http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.core.windows.net/
##[debug]Unable to get registry authentication token with given registryURL. Please make sure that the MSI is correctly configured
##[error]Unhandled: Could not fetch access token for Managed Service Principal. Please configure Managed Service Identity (MSI) for virtual machine 'https://aka.ms/azure-msi-docs'. Status code: %s, status message: %s
    at ACRAuthenticationTokenProvider.<anonymous> (.../azure-pipelines-tasks-docker-common/registryauthenticationprovider/acrauthenticationtokenprovider.js:130:27)
```

## Root cause & fix

- **Root cause:** With multiple user-assigned identities on the agent, the Docker task's IMDS
  token request omits the `client_id`/`mi_res_id`, so Azure cannot resolve which identity to mint
  a token for. ACR login never happens.
- **Fix shown:** Either keep a **single** identity on the agent/pool used by that service
  connection, **or** authenticate explicitly:
  ```bash
  az login --identity --username <IDENTITY_A_CLIENT_ID>
  az acr login --name <ACR_NAME>
  ```

## Reset between runs

- **Fail again:** ensure both identities are attached to the VM.
- **Succeed:** detach one identity, or use the pinned-identity script step.

## Cleanup

```bash
azd down --purge --force
```
