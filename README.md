# Multi-identity ACR auth failure on Azure Pipelines (`tdd-multi-identity-acr-auth`)

A Trainer Demo Deploy scenario that **reproduces a real Azure DevOps support case**
(2605130050002742): a Docker-task Managed Service Identity authentication failure that occurs when
**two or more user-assigned managed identities** are attached to a build agent. One `azd up`
stands up the entire lab — the multi-piece environment engineers normally assemble by hand — so
the time goes to the diagnosis, not the plumbing.

> This is a **deliberate failure-reproduction** scenario. The failing pipeline is the point; the
> fix is demonstrated in the pipeline, not patched out of the infrastructure.

## What this deploys

- VNet + subnet + NSG (SSH locked to your CIDR)
- Public IP + NIC
- **Two user-assigned managed identities** (the trigger condition)
- Azure Container Registry (Basic)
- **AcrPull + AcrPush on both identities** (so the failure is pure identity ambiguity, never a
  missing-permission red herring)
- Ubuntu 22.04 self-hosted Azure Pipelines agent VM with **both** identities attached, bootstrapped
  to install Docker + Azure CLI and auto-register into your Azure DevOps pool

## Architecture

```
                 ┌──────────────────────────── Resource Group (rg-<env>) ───────────────────────────┐
                 │                                                                                   │
  Azure DevOps   │   ┌──────────────┐        ┌───────────────────────────┐        ┌──────────────┐  │
  org / pipeline │   │   VNet/NSG   │        │  Ubuntu self-hosted agent │        │     ACR      │  │
  (Docker task,  │   │   + Public IP├────────┤  VM                       ├────────┤  (Basic)     │  │
   MSI service   │   └──────────────┘        │  identity = { id-a, id-b }│  MSI   └──────┬───────┘  │
   connection)   │                           └───────────────────────────┘   token      │          │
        │        │                                  ▲        ▲                           │          │
        └────────┼──────────────────────────────────┘        └── AcrPull+AcrPush ────────┘          │
   registers &   │            two user-assigned identities attached ⇒ IMDS cannot resolve which     │
   runs the job  │            identity ⇒ Docker task ACR auth fails on every run                     │
                 └───────────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure subscription where you can create role assignments (Owner or User Access Administrator)
- A **sandbox** Azure DevOps org (do **not** use a customer's org)
- An ADO **PAT** with *Agent Pools (read & manage)*
- An SSH public key
- `azd` and `az` CLIs, logged in

## Deploy

```bash
# Create a self-hosted pool named "demodeploy-repro-pool" in your sandbox org first.
azd init -t tdd-multi-identity-acr-auth
azd env set ADO_ORG_URL          https://dev.azure.com/<your-sandbox-org>
azd env set ADO_PAT              <your-PAT>
azd env set ADMIN_SSH_PUBLIC_KEY "$(cat ~/.ssh/id_rsa.pub)"
azd env set ALLOWED_SSH_CIDR     <your.ip>/32
azd up
```

azd outputs you'll use: `ACR_NAME`, `ACR_LOGIN_SERVER`, `IDENTITY_A_CLIENT_ID`,
`IDENTITY_B_CLIENT_ID`, `AGENT_PUBLIC_IP`, `SSH_COMMAND`.

## Reproduce the failure

1. In your sandbox project: **Project Settings → Service connections → New → Docker Registry →
   Azure Container Registry**, auth **Managed Identity**, point at `ACR_NAME`, name it **`acr-msi-sc`**.
2. Push this repo to the project, create a pipeline from `src/azure-pipelines.yml`, run it on
   `demodeploy-repro-pool`.
3. The Docker task **fails on every run** with the customer's exact error (see `demoguide/demoguide.md`).

## Show the fix

- Detach one identity from the VM (Portal → VM → Identity), re-run → **succeeds**; **or**
- Use the pinned-identity script step at the bottom of `src/azure-pipelines.yml`
  (`az login --identity --username <IDENTITY_A_CLIENT_ID>`), re-run → **succeeds** even with both
  identities attached.

## Cost & cleanup

- ~$2–4/day (ACR Basic + a small D-series VM). Deploy, demo, tear down.
- `azd down --purge --force` removes everything.

## Notes

- `agentVersion` is pinned in `infra/resources.bicep`; bump it if agent registration fails on an
  older build.
- The PAT is passed via cloud-init on a throwaway VM — fine for a short-lived demo; delete the lab
  when done.
- `vmSize` defaults to `Standard_D2s_v5`; override with `azd env set VM_SIZE <sku>` if your
  subscription/SFI policy requires a different SKU.

## Repo layout

```
tdd-multi-identity-acr-auth/
├─ azure.yaml                      # azd template definition
├─ infra/
│  ├─ main.bicep                   # subscription-scope entry (creates RG)
│  ├─ resources.bicep              # the lab resources
│  └─ main.parameters.json         # azd env-var bindings
├─ src/
│  ├─ azure-pipelines.yml          # failing pipeline + commented fix
│  └─ Dockerfile                   # trivial image
├─ demoguide/
│  └─ demoguide.md                 # run-of-show + talk track
├─ .github/
│  └─ copilot-instructions.md      # scenario guardrails for AI agents
└─ README.md
```

**Author:** Aman Srivastava — Escalation Engineer, CSS Azure DevOps
