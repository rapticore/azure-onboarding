# Azure Infrastructure Deployment

This project provides Terraform/OpenTofu modules for deploying Azure infrastructure components including RTTM (Real-Time Threat Monitoring) and Managed Identity resources.

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.6.0
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) >= 2.0
- Azure subscription with appropriate permissions
- PowerShell or Bash terminal

## Quick Start

### Step 1: Azure Authentication

Login to Azure and set your subscription:

```bash
az login
az account set --subscription "your-subscription-id"
```

### Step 2: Bootstrap Remote State Storage

Before deploying the main infrastructure, you need to set up Azure Storage for Terraform state management.

```bash
cd bootstrap-tfstate
tofu init
tofu plan
tofu apply
```

This will create:

- Azure Storage Account
- Blob Container for storing Terraform state
- Necessary access permissions

**Important:** Note down the storage account name and container name from the output - you'll need these for the next step.

### Step 3: Configure Backend

After the bootstrap completes, edit `deployment/backend.tf` and replace the three
placeholders with the values printed by the bootstrap step (its `resource_group_name`,
`storage_account_name` and `container_name` outputs). Backend blocks cannot use
variables, so these are filled in by hand:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "<your-tfstate-resource-group>"
    storage_account_name = "<your-tfstate-storage-account>"
    container_name       = "<your-tfstate-container>"
    key                  = "onboarding.terraform.tfstate"
  }
}
```

### Step 4: Configure Variables

First create local build of Function App
This build will then be packaged by Terraform in zip file to deploy Function App by Zip Deploy method.
You need to have Python minimum 3.12 for this

```bash
cd modules/rttm/function-app

pip install -r requirements.txt --target="./.python_packages/lib/site-packages"
```

Then

Copy the example variables file and customize it for your environment:

```bash
cd deployment
cp tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your specific values:

```hcl
# Example values - customize for your environment
resource_group_name = "rg-myproject-prod"
location           = "eastus"

```

### Step 5: Deploy Infrastructure

Initialize and deploy the infrastructure:

```bash
cd deployment
tofu init
tofu plan
tofu apply
```

## Module Documentation

### RTTM Module

The Real-Time Threat Monitoring module streams your Azure Activity Log and your Entra ID
directory + sign-in logs to Rapticore in near real time.

**Location:** `modules/rttm/`

**What it deploys:** an Event Hubs namespace + hub, a consumer group, a Linux Function
App (Python 3.12, Consumption plan) with Application Insights and a storage account, a
subscription-level diagnostic setting for the control-plane Activity Log categories, and
a tenant-level Entra diagnostic setting for the directory audit + sign-in log categories.

#### Diagnostic log categories collected

Subscription **Activity Log** (`azurerm_monitor_diagnostic_setting`, no license
requirement — works on any subscription):

| Category | What it captures |
| --- | --- |
| `Administrative` | All ARM create/update/delete/action operations, including RBAC role-assignment changes |
| `Security` | Microsoft Defender for Cloud alerts (empty if Defender for Cloud is not generating alerts) |
| `Policy` | Azure Policy audit/deny effect operations |
| `Alert` | Activations of Azure alert rules |

Tenant **Entra ID** (`azurerm_monitor_aad_diagnostic_setting`; the setting as a whole
requires at least one Entra ID **P1** license because of the sign-in categories):

| Category | What it captures |
| --- | --- |
| `AuditLogs` | Directory changes — app credential/secret adds, OAuth consent grants, new federated credentials, PIM activations, Conditional Access policy changes, directory-role changes. The highest-signal identity events. |
| `SignInLogs`, `NonInteractiveUserSignInLogs`, `ServicePrincipalSignInLogs`, `ManagedIdentitySignInLogs`, `ADFSSignInLogs`, `MicrosoftServicePrincipalSignInLogs` | Interactive and workload sign-in activity |

`AuditLogs` on its own has no premium-license requirement, but it rides on the same Entra
diagnostic setting as the sign-in categories, which collectively require P1.

#### Entra ID Protection risk logs (optional — needs Entra ID P2)

Two further Entra categories, **`RiskyUsers`** and **`UserRiskEvents`**, are produced by
Microsoft Entra ID Protection and require an **Entra ID P2** license. They are gated
behind an opt-in variable so a non-P2 tenant's `apply` still succeeds:

| Variable | Default | Effect |
| --- | --- | --- |
| `enable_entra_id_protection_logs` | `false` | When `true`, adds `RiskyUsers` and `UserRiskEvents` to the Entra diagnostic setting. Set this only if the tenant has Entra ID P2; on a non-P2 tenant `apply` fails on these categories. |

**How it reaches Rapticore:** the Function App uses its user-assigned managed identity to
get a token, exchanges it for temporary AWS credentials via
`AssumeRoleWithWebIdentity`, and calls SQS `SendMessage`. No AWS access keys are stored.

#### Permissions and consent the customer must grant

These are checked at `tofu apply` time. The subscription-Owner role that covers the rest
of onboarding is **not** sufficient for the last two rows.

| Scope | Required role | Needed for |
| --- | --- | --- |
| Resource group | `Contributor` | Event Hub, Function App, storage account, App Insights, Log Analytics |
| Subscription | `Owner` or `Monitoring Contributor` | The Activity Log diagnostic setting (`azurerm_monitor_diagnostic_setting` on the subscription) |
| Event Hub authorization rule | `ListKeys` (implied by the roles above) | Azure Monitor reads the rule's key to stream. The rule is created with `listen`, `send` and `manage` because Azure requires all three for Event Hub streaming — do not narrow them |
| **Entra ID tenant** | **`Security Administrator`** | The Entra diagnostic setting that exports directory **audit** and sign-in logs (`azurerm_monitor_aad_diagnostic_setting`). This is a directory role, not an Azure RBAC role |
| **Entra ID tenant** | **`Global Administrator`** or **`Privileged Role Administrator`** | Only if you also apply the managed-identity module's Microsoft Graph app-role block — assigning a Graph app role *is* the admin consent |

#### Licensing prerequisite (Entra sign-in logs only)

Exporting Entra ID **sign-in** logs through diagnostic settings requires at least one
**Entra ID P1 or P2** license in the tenant; the Free tier does not offer diagnostic
settings for these logs. It is a tenant-wide requirement — you do not need a license per
user.

The **Activity Log** half of this module has no such requirement and works on any
subscription. If your tenant is Free tier, expect
`azurerm_monitor_aad_diagnostic_setting` to fail while everything else succeeds; remove
that resource (or acquire one P1 license) and Activity-Log monitoring still works.

#### Inputs Rapticore provides

Set these in your `terraform.tfvars`. Rapticore supplies all four from your tenant's
CloudFormation stack outputs:

- `aws_sqs_queue_url` — the `RealTimeThreatAlertTriggerAzureQueueURL` output, of the form
  `https://sqs.us-west-2.amazonaws.com/<rapticore-account>/real-time-threat-alert-trigger-azure-<tenant>`
- `aws_role_arn` — `arn:aws:iam::<rapticore-account>:role/AzureWebIdentityRoleForAzureRTTM-<tenant>`
- `aws_oidc_audience` — `api://<your-azure-tenant-id>`
- `aws_region` — normally `us-west-2`

#### Expected delay before the first event

Microsoft documents that it can take **up to three days** for logs to begin appearing at
a newly configured diagnostic-setting destination. An empty queue immediately after
`tofu apply` is normal and not evidence of a misconfiguration.

#### Upgrading from an earlier revision of this module

Earlier revisions built the storage account name and the Event Hub authorization rule
name with `uuid()`, and the code blob name with `timestamp()`. Because those functions
return a new value on every evaluation, **every `tofu apply` destroyed and recreated the
storage account** and churned the authorization rule that the Function App and both
diagnostic settings depend on.

Names are now derived deterministically from your subscription id and resource group, so
applies are idempotent. The first apply after upgrading will show a one-time replacement
of the storage account, the authorization rule and the code blob. This is expected and
is the last time it should happen.

If you must keep an existing storage account instead, pin it:

```hcl
function_storage_account_name = "your-existing-account-name"
```

### Managed Identity Module

The Managed Identity module creates and configures Azure Managed Identity resources for secure authentication.

**Location:** `modules/managed-identity/`

### Remediation Module (optional — grants WRITE access)

**Location:** `modules/remediation/`

By default Rapticore onboarding is **read-only**. This module is the single place that
grants Azure **write** access, and it is **opt-in and off by default**. Leave
`enable_remediation_write = false` (the default) and this module creates nothing — no
identity, no role, no role assignment, no credential.

Enable it only if you want Rapticore to perform **automated remediation**: guardrails,
one-click, and reactive remediation all perform ARM writes. Enabling it is a security
decision for your organization (see below).

**What it deploys when enabled:**

- A **separate** user-assigned managed identity (`rapticore-remediation-write-uami` by
  default) used *only* as the remediation write principal. It is deliberately distinct
  from the read/scanner identity: Rapticore's remediation engine refuses to run unless
  the write identity's client id differs from the scanner's client id
  (`AZURE_REMEDIATION_WRITE_CLIENT_ID` ≠ read client id).
- A **least-privilege custom role** (`RapticoreRemediationWriteRole`) granting exactly
  the control-plane actions the shipped remediations use — and nothing else:

  | Action | Used by |
  | --- | --- |
  | `Microsoft.Storage/storageAccounts/read` + `/write` | Storage remediations (public-blob, min-TLS, secure-transfer, soft-delete, infra-encryption) |
  | `Microsoft.Storage/storageAccounts/listkeys/action` + `/regeneratekey/action` | Storage access-key rotation |
  | `Microsoft.Web/sites/read` + `/write` | App Service / Function App remediations (auth, HTTPS redirect, min-TLS, client-cert, runtime, FTP, public access, managed identity) |
  | `Microsoft.Network/networkSecurityGroups/read` + `/write` | NSG remediations (restrict internet SSH/RDP/UDP) |

  A custom role is used **instead of built-in roles** on purpose. The closest built-ins
  are materially broader: *Storage Account Contributor* adds delete across all storage,
  *Website Contributor* adds server-farm and certificate management, and there is no
  NSG-only built-in — the only built-in that covers NSG writes is *Network Contributor*,
  which grants `Microsoft.Network/*` (every network resource type). The custom role adds
  no delete and no unrelated resource types.
- A **federated identity credential** using the same OIDC exchange as the scanner
  identity (audience `api://AzureADTokenExchange`). Rapticore supplies the issuer and
  subject; the subject must differ from the scanner's subject.

**Scope:** the role is defined and assigned at `role_scope` (usually the subscription) by
default. Set `remediation_role_scope` to a single resource group to give writes a smaller
blast radius than reads.

**Deployer permissions:** creating a custom role definition and a role assignment
requires the person running `tofu apply` to have **Owner** or **User Access
Administrator** at the chosen scope (the same requirement as the scanner's custom role).

**Variables:**

| Variable | Default | Notes |
| --- | --- | --- |
| `enable_remediation_write` | `false` | Master opt-in. Off = zero write grant. |
| `remediation_role_scope` | `""` | Empty reuses `role_scope`; set an RG id to scope tighter. |
| `remediation_identity_name` | `rapticore-remediation-write-uami` | Write identity name. |
| `remediation_custom_role_name` | `RapticoreRemediationWriteRole` | Kept distinct from the scanner role. |
| `remediation_federated_credential_name` | `""` | Required when enabled. Provided by Rapticore. |
| `remediation_federated_credential_issuer` | `""` | Required when enabled. Provided by Rapticore. |
| `remediation_federated_credential_subject` | `""` | Required when enabled. Provided by Rapticore; must differ from the scanner subject. |
| `remediation_federated_credential_audience` | `api://AzureADTokenExchange` | Keep identical to the scanner audience. |

When `enable_remediation_write = true`, the `_name`, `_issuer` and `_subject` values are
required; a `precondition` fails the plan with a clear message if any is missing.

**Outputs to hand back to Rapticore (only populated when enabled):**

| Output | Maps to |
| --- | --- |
| `remediation_write_client_id` | `AZURE_REMEDIATION_WRITE_CLIENT_ID` and the capability grant's `credentialClientId` |
| `remediation_write_principal_id` | the capability grant's `providerPrincipalId` |
| `remediation_write_scope` | the capability grant's `selectedScopes` for each `azure.direct-remediation/<actionId>` |
| `remediation_write_federated_audience` | the federated-credential audience (matches the scanner) |
| `remediation_write_role_definition_id` | the custom role definition resource id |

**Security implications (a customer decision):** enabling this lets Rapticore change your
storage accounts, web/function apps, and network security groups within the chosen scope.
Rapticore additionally fences writes behind its own runtime kill-switches (a global
enable flag, a per-action allowlist, and a per-account allowlist), but from your tenant's
perspective the grant above is real standing write access for the write identity. If you
only want posture and detection, leave `enable_remediation_write = false`.

## Onboarding one Azure tenant to MORE THAN ONE Rapticore tenant

Sometimes the same Azure tenant needs to be read by two Rapticore tenants — a staging
Rapticore tenant alongside production, or an internal test tenant. That is supported;
what it takes depends on which half of the integration you mean.

### Scanning (Rapticore → Azure) — one extra federated credential, no new Azure resources

Every Rapticore tenant has its own AWS Cognito identity pool, so it presents a different
token `subject`. A single user-assigned managed identity can trust up to **20** federated
credentials, so both Rapticore tenants can federate to the **same** scanning identity:

```hcl
# terraform.tfvars — the primary credential stays exactly as-is
federated_credential_name    = "rapticore-oidc"
federated_credential_subject = "<subject Rapticore gave you for tenant A>"

additional_federated_credentials = [
  {
    name    = "rapticore-oidc-staging"
    subject = "<subject Rapticore gave you for tenant B>"
  },
]
```

`audience` and `issuer` are optional and default to the primary credential's values,
which is correct for every Rapticore tenant. No new identity, role assignment or cost.

Verify with the `federated_credential_subjects` output.

> Existing deployments migrate cleanly: a `moved` block maps the previously-singular
> credential onto the map key `primary`, so `tofu plan` shows **no** destroy/recreate.

### Real-time threat monitoring (Azure → Rapticore) — read this before duplicating

RTTM is a forwarder: Entra/Activity diagnostic logs → Event Hub → Function App → the
Rapticore tenant's SQS queue. It is **not** free to run twice.

- **If you only need to move RTTM to a different Rapticore tenant**, just change
  `aws_sqs_queue_url` and `aws_role_arn` and re-apply. Nothing else to do — that is
  the cheap and usually correct answer.
- **If you genuinely need both tenants receiving events simultaneously**, set
  `rttm_deployment_suffix` and use a **separate resource group** and a **separate
  Terraform state key**. The suffix is required because the Function App name
  (`<name>.azurewebsites.net`) and the Event Hub namespace name
  (`<name>.servicebus.windows.net`) are globally unique, and the Entra diagnostic
  setting name is unique per Azure tenant.

  ```hcl
  resource_group_name    = "rapticore-rttm-staging-rg"
  rttm_deployment_suffix = "staging"
  ```

  Cost: this duplicates the Event Hub namespace, Function App, storage account and
  Log Analytics workspace, and streams the *same* Entra diagnostic logs twice. Azure
  also caps diagnostic settings at 5 per resource.

### On the AWS side

Nothing for you to do — Rapticore's per-tenant stack now *adopts* the shared IAM OIDC
provider for your tenant rather than trying to create a second one, and never deletes it
while another tenant still depends on it.

## State Management

This project uses Azure Blob Storage as the backend for Terraform state. The state is stored remotely to enable:

- Team collaboration
- State locking
- State versioning and backup
- Secure state storage

## Environment Management

To manage multiple environments (dev, staging, prod), you can:

1. Create separate `.tfvars` files for each environment
2. Use workspace-specific state keys in your backend configuration
3. Deploy with environment-specific variable files:

```bash
tofu apply -var-file="dev.tfvars"
tofu apply -var-file="prod.tfvars"
```

## Common Commands

```bash
# Initialize the working directory
tofu init

# Create an execution plan
tofu plan -var-file="terraform.tfvars"

# Apply the changes
tofu apply -var-file="terraform.tfvars"

# Show current state
tofu show

# Destroy infrastructure (use with caution)
tofu destroy -var-file="terraform.tfvars"
```

## Teardown / Offboarding

To remove everything this project created in your tenant:

```bash
cd deployment
tofu destroy -var-file="terraform.tfvars"
```

This removes the RTTM resources (Event Hub namespace and hub, Function App, its
storage account, Application Insights and Log Analytics), both diagnostic settings,
the scanning managed identity with its custom role and role assignment, and — only if
you had enabled it — the remediation write identity, its custom role and its role
assignment. Once the remediation write identity is destroyed, Rapticore holds no write
grant in your tenant.

The Terraform state storage created in the `bootstrap-tfstate` step is separate and is
**not** removed by the command above. Destroy it last, after the deployment destroy has
completed, if you no longer need the state:

```bash
cd ../bootstrap-tfstate
tofu destroy -var-file="terraform.tfvars"
```

## Troubleshooting

### Backend Configuration Issues

- Ensure the storage account and container exist before running `tofu init`
- Verify your Azure credentials have access to the storage account
- Check that the storage account name is globally unique

### Module Issues

- Verify all required variables are set in your `.tfvars` file
- Check Azure permissions for the resources being created
- Review the module documentation for specific requirements

## Contributing

1. Follow the existing code structure and naming conventions
2. Update documentation when adding new features
3. Test changes in a development environment before applying to production
4. Use meaningful commit messages and create pull requests for review

## Security Considerations

- Never commit `.tfvars` files containing sensitive data to version control
- Use Azure Key Vault for storing secrets referenced in your infrastructure
- Regularly rotate access keys and review permissions
- Enable Azure Security Center recommendations for deployed resources

## Support

For issues or questions:

1. Check the troubleshooting section above
2. Review Azure and OpenTofu documentation
3. Create an issue in the project repository with detailed error messages and steps to reproduce
