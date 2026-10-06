# Fabric Gen2 Ontology and Data Agent: A Tested Snapshot Bypass

This lab investigates new-experience (Gen2) Ontology integration with Fabric Data Agent and tests an explicit context-snapshot bypass. Infrastructure is isolated in a dedicated Azure resource group and deployed with Azure CLI and Bicep. Only synthetic data and reviewed, aggregate results belong in the public repository. Gen1 is not the focus of the current experiments.

**Experimental lab, not an official Microsoft workaround or a native Gen2 integration fix.** Results describe the tested service behavior on October 5-6, 2026. Preview APIs and service behavior can change.

## How It Works

An ontology describes business entities, properties, relationships and their mappings to data. In this lab, it defines machines and anomalies, including what makes an anomaly actionable. The Data Agent needs those definitions to interpret questions and the underlying Lakehouse tables to obtain the actual answers.

The native ontology attachment failed in the tested configurations. The bypass keeps the Gen2 ontology as the authoring source, exports its TMDL definition, and supplies that definition as instructions to a Data Agent connected directly to the Lakehouse:

```text
Gen2 ontology -- explicit TMDL export --> agent and source instructions
                                              |
User question --------------------------> Data Agent
                                              |
                                      selected Lakehouse tables
                                              |
                                            answer
```

Only metadata is copied into instructions, not rows or expected answers. A data change therefore does not require a new snapshot; a change to business definitions or mappings does. This is why the verification changes a source value and checks that the answer follows it without republishing the agent. It does not establish native ontology execution, automatic context refresh or equivalent governance.

Start with the [test results](results/2026-10-06.json) and the [snapshot lifecycle](#snapshot-lifecycle) for the evidence and maintenance model. The sections below cover prerequisites, deployment, API operations and repeatable tests. Cloud tests create billable resources and must run only in an isolated synthetic lab.

## Current Status

The lab uses a dedicated Fabric F2 capacity in **Sweden Central**, a `MaintenanceData` lakehouse, a Gen2 ontology and a Lakehouse-backed Data Agent. Fabric items are managed through public APIs.

The seed notebook completed successfully, including five SQL assertions over five machines and six anomalies. The expected actionable-anomaly count is **3**, affecting **M01 and M03**, with **55 minutes** of downtime. **M05** has no anomalies.

**Gen2 creation passed:** `MaintenanceNew` was created from TMDL. The item API explicitly reports `generation: 2`, and `getDefinition` returned 11 parts. Ontology MCP successfully listed both entities, keys, property bindings and the business definition. The definition uses top-level `ref` statements in `model.tmdl`.

**Native attachment failed in three configurations:** ontology alone; Lakehouse mounted first; and after reimporting the service-normalized TMDL. All three submissions returned HTTP 202, then the operation failed with `BadRequest`, `isRetriable=false`, and **"Failed to fetch schema for the data source."** The Lakehouse attachment itself succeeded. These observations are specific to this lab and the SDK-equivalent public API; the portal attachment route was not tested.

**A snapshot bypass passed the answer checks:** the script reads the actual Gen2 definition, records its SHA-256, and supplies its definitions and mappings as agent and Lakehouse instructions. It selects the two synthetic tables and publishes the agent. Two runs of the four questions returned all expected answers: **8/8 answer-text matches**. This is not a successful native Gen2 attachment. Native Ontology MCP `ask_ontology` failed all four questions with **"Something went wrong while loading the ontology definition"**, despite `is_error=false`.

**Data-freshness verification passed on 2026-10-06:** with the same published instructions and ontology hash, a reversible source-data change moved the agent's downtime answer from **55 to 92 and back to 55 minutes**. The main baseline/change/restore campaign matched **12/12 phase-specific answers**; an additional four-question changed-data run also matched. The stale 55-minute oracle was correctly rejected with a nonzero exit. All three source-validation notebooks completed, and the original fixture was restored.

See the [native-integration results](results/2026-10-05.json) and [bypass verification results](results/2026-10-06.json). After verification, a fresh ARM read confirmed the capacity **Paused**, with provisioning **Succeeded**. Suspend the capacity between experiments; stored data can still incur charges.

## Prerequisites and Checks

Use PowerShell 7, Azure CLI and Python 3.13. Authenticate Azure CLI for your own test tenant and subscription using a project-local `AZURE_CONFIG_DIR` pointing to `.azure`. No credentials or live workspace state are included in this repository. Never upload the CLI cache, browser profiles, HAR files, or raw authentication logs.

Set up the Python environment and run the offline checks before provisioning anything:

```powershell
python -m venv .venv
./.venv/Scripts/python.exe -m pip install -r requirements.txt
./tests/Test-FabricAccess.Tests.ps1
./tests/FabricApi.Tests.ps1
./.venv/Scripts/python.exe -m unittest discover -s tests -p test_lab_mcp.py -v
```

These examples use Windows paths. With your Azure CLI session authenticated, check Fabric access:

```powershell
./scripts/Test-FabricAccess.ps1
```

The script makes read-only calls, restores the original `AZURE_CONFIG_DIR`, prints an aggregate result, and writes account identifiers only to the ignored `.local/access-check.json`. Successful preflight is required before running the integration tests.

```powershell
./tests/Test-FabricAccess.Tests.ps1
./tests/FabricApi.Tests.ps1
```

The preflight suite passed **24 assertions across three simulated cases**. The API/definition suite passed **74 assertions**, including top-level TMDL references and guarded data-freshness test generation. Four Python unit tests check answer matching, changed-data totals and textual errors incorrectly marked successful by MCP. These tests do not prove server-side SQL execution.

The test identity needs applicable Fabric access, workspace permissions and enabled Ontology and Data Agent tenant settings. A Fabric administrator must enable **Users can create Ontology (preview) items**, preferably through a scoped security group. See [required ontology tenant settings](https://learn.microsoft.com/fabric/iq/ontology/overview-tenant-settings). Do not enable unrelated tenant-wide or cross-geography options. Resume the existing capacity and reconcile journals with live state before making changes. Preserve failed test evidence; the scripts deliberately refuse blind replay.

## Infrastructure

[infra/main.bicep](infra/main.bicep) creates exactly one F2 capacity. The administrator is supplied at runtime. The default capacity name is deterministic for the resource group, which prevents accidental duplicate capacities when repeating a deployment. Keep the same region on subsequent deployments.

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $PWD '.azure'
$subscription = az account show --query id -o tsv
$administrator = az account show --query user.name -o tsv
$resourceGroup = 'rg-fabric-ontology-gen2-lab'
az group create --subscription $subscription --name $resourceGroup --location swedencentral --tags project=fabric-ontology-gen2-lab purpose=issue-reproduction lifecycle=temporary
az provider register --subscription $subscription --namespace Microsoft.Fabric --wait
az deployment group validate --subscription $subscription --resource-group $resourceGroup --template-file ./infra/main.bicep --parameters "administrator=$administrator" location=swedencentral
az deployment group what-if --subscription $subscription --resource-group $resourceGroup --template-file ./infra/main.bicep --parameters "administrator=$administrator" location=swedencentral
az deployment group create --subscription $subscription --resource-group $resourceGroup --name ontology-gen2-capacity --template-file ./infra/main.bicep --parameters "administrator=$administrator" location=swedencentral --mode Incremental
```

The supplied workspace helper deliberately requires an F2 in Sweden Central. Confirm that region is available to your subscription; choosing another region requires reviewing that guard and feature availability. Resource-group metadata location and capacity location are independent. Validate the deployment and review what-if before provisioning; this template should create exactly one capacity.

Fabric workspaces, lakehouses, ontologies and data agents are Fabric items, not ARM children of the resource group. Their creation and lifecycle require separate Fabric API operations.

## API Workflow

`scripts/FabricApi.ps1` uses only the workspace CLI cache and the official Fabric API host. It records request/response evidence under ignored `.local/api`, without access tokens or Authorization headers. HTTP 202 means pending, not completed. `scripts/New-LabItem.ps1` checks workspace ownership and journals submissions before mutation to prevent uncertain operations from being replayed.

```powershell
./scripts/New-LabWorkspace.ps1 -CapacityId '<Fabric capacity GUID>'
./scripts/New-LabItem.ps1 -Type Lakehouse -Name MaintenanceData
./scripts/New-LabItem.ps1 -Type DataAgent -Name MaintenanceDirect
./scripts/New-LabSeedNotebook.ps1
```

If notebook creation returns 202, verify its operation reaches `Succeeded` before starting it. These commands apply to a new installation; the current lab has already completed its seed run:

```powershell
./scripts/New-LabSeedNotebook.ps1 -Start
./scripts/New-LabSeedNotebook.ps1 -CheckRun
```

Respect the response `Retry-After` interval before checking. The seed script refuses a second submission when its run journal exists. The SQL fixture replaces only the dedicated lab's `dbo.Machines` and `dbo.Anomalies` tables. Never run it against a production lakehouse. The expected agent answers and business rule are in [fixtures/questions.json](fixtures/questions.json); the executable fixture and assertions are in [fixtures/maintenance.sql](fixtures/maintenance.sql).

`scripts/OntologyDefinition.ps1` provides `New-LabOntologyDefinition -Experience Gen1|New`, parameterized by workspace, lakehouse and SQL endpoint identifiers. It emits the definition object accepted by `New-LabItem.ps1 -Definition`. Use `-Experience New` for these experiments. Gen2 service import and returned-definition checks passed. The legacy Gen1 branch is outside the validated scope.

Create the Gen2 ontology with identifiers from your own completed workspace and Lakehouse creation. Obtain the SQL endpoint ID and server from that Lakehouse's metadata; the SQL endpoint ID is not the Lakehouse ID. Replace the placeholders before running:

```powershell
. ./scripts/OntologyDefinition.ps1
$parameters = @{
    Experience = 'New'
    WorkspaceId = '<workspace GUID>'
    LakehouseId = '<Lakehouse GUID>'
    SqlEndpointId = '<SQL endpoint GUID>'
    SqlServer = '<server>.datawarehouse.fabric.microsoft.com'
}
$definition = New-LabOntologyDefinition @parameters
./scripts/New-LabItem.ps1 -Type Ontology -Name MaintenanceNew -Definition $definition
```

Require the creation operation to succeed before continuing. Confirm that the ontology metadata reports `generation: 2`; an accepted request or a display name alone does not establish that the intended experience was created.

## Gen2 Experiments

Use Python 3.13 in a workspace-local virtual environment and install [requirements.txt](requirements.txt). The live versions were `fabric-data-agent-sdk 0.1.32a0` and `mcp 2.2.0`. The public REST attachment request matches the installed SDK's `add_staging_datasource` implementation; no private service API is used. The MCP client uses the verified 2.x signatures, which differ from older documentation samples.

For a fresh lab with `MaintenanceNew` and `MaintenanceData` already created:

```powershell
./scripts/New-LabItem.ps1 -Type DataAgent -Name MaintenanceGen2
./scripts/Invoke-LabTimed.ps1 -FilePath pwsh -Arguments @('-NoProfile', '-File', './scripts/Test-LabGen2.ps1', '-Action', 'Attach')
```

Inspect the returned operation through `GET /v1/operations/{operationId}` after `Retry-After`. Do not run the next mutation until the previous operation is terminal. The standard attempt failed in this lab; after checking the operation and confirming no ontology source remained:

```powershell
./scripts/Test-LabGen2.ps1 -Action Mount
# Wait for the Lakehouse operation to succeed, then:
./scripts/Test-LabGen2.ps1 -Action Attach -Attempt lakehouse-first
# After the second attachment failure, reimport the returned TMDL:
./scripts/Test-LabGen2.ps1 -Action ResaveOntology -Attempt normalized-tmdl
# Only after reimport completes:
./scripts/Test-LabGen2.ps1 -Action Attach -Attempt normalized-tmdl
```

Each mutation has a private journal and must not be replayed blindly. The scripts intentionally refuse an existing attempt journal. The existing live lab has already run these commands.

The successful, explicitly non-native bypass is:

```powershell
./scripts/Invoke-LabTimed.ps1 -FilePath pwsh -Arguments @('-NoProfile', '-File', './scripts/Test-LabGen2.ps1', '-Action', 'ConfigureSnapshot')
./scripts/Test-LabGen2.ps1 -Action Publish -Attempt snapshot
./scripts/Invoke-LabTimed.ps1 -FilePath './.venv/Scripts/python.exe' -Arguments @('./scripts/Test-LabMcp.py', '--target', 'agent', '--suite')
./scripts/Invoke-LabTimed.ps1 -FilePath './.venv/Scripts/python.exe' -Arguments @('./scripts/Test-LabMcp.py', '--target', 'ontology', '--suite')
./.venv/Scripts/python.exe -m unittest discover -s tests -p test_lab_mcp.py -v
```

The timer emits progress every **120 seconds** and limits each child activity to **1,200 seconds (20 minutes)**. Timeout ends only the local process tree; it does not cancel a Fabric operation. Reconcile remote state and private evidence before resuming. Do not pass secrets in command arguments.

Raw MCP responses and context snapshots stay under ignored `.local`. `phase: Completed` means the protocol exchange completed, not that answers were correct. Inspect `assessment` and `answerTextOraclePassed` separately. Answer-text matching is a deliberately narrow check for this fixture, not a general evaluator or proof of executed SQL.

The suite exits nonzero when any expected answer does not match. An MCP response with `is_error=false` is not sufficient evidence of success.

## Snapshot Lifecycle

The bypass connects the Data Agent directly to the Lakehouse. It exports the Gen2 ontology's TMDL metadata and copies that metadata into agent-level and source-level instructions. Ontology remains the source of business definitions, but the native ontology attachment is absent.

- **Data rows change:** no context export or agent publication is needed. The source remains the Lakehouse; normal source visibility and synchronization delays still apply.
- **Definitions, mappings or schema change:** review the change, regenerate the snapshot, republish and repeat the tests. The copied context does not refresh automatically.
- **Verification:** `VerifySnapshot` compares both published instruction fields with a fresh ontology export, checks the sole Lakehouse source and selected tables, and records the context hash.

With the lab capacity active, use a new reviewed attempt label for each configuration or verification:

```powershell
./scripts/Test-LabGen2.ps1 -Action ConfigureSnapshot -Attempt reviewed-v2
./scripts/Test-LabGen2.ps1 -Action Publish -Attempt reviewed-v2
./scripts/Test-LabGen2.ps1 -Action VerifySnapshot -Attempt reviewed-v2
./scripts/Invoke-LabTimed.ps1 -FilePath './.venv/Scripts/python.exe' -Arguments @('./scripts/Test-LabMcp.py', '--target', 'agent', '--suite')
```

This implementation is deliberately limited to the two-table lab. Production use would require an approved synchronization workflow, versioned snapshots and rollback, instruction-size checks, metadata access controls and a broader regression suite. Those capabilities are not implemented here. Copies of metadata do not inherit live ontology governance automatically; underlying data permissions still apply.

Using source instructions for business rules and join guidance is a [documented configuration pattern](https://learn.microsoft.com/fabric/data-science/data-agent-configuration-best-practices). Exporting Gen2 TMDL into those instructions is this lab's experimental application of that pattern, not a documented Microsoft fix for native ontology attachment.

## Data Freshness Test

[scripts/Test-LabFreshness.ps1](scripts/Test-LabFreshness.ps1) generates lab-only notebooks with three modes. Each notebook asserts the complete expected source rows before proceeding. `Mutate` changes only A01's downtime from 10 to 47; `Restore` requires the changed fixture and puts that value back to 10. Each mode checks the resulting actionable-anomaly total independently in Spark.

| Phase | Expected Downtime | Required Agent Check |
| --- | --- | --- |
| Baseline | 55 minutes | All four original questions match |
| Mutate | 92 minutes | Q04 changes to 92; the other answers stay unchanged |
| Restore | 55 minutes | All four original questions match again |

Run each phase separately, using `-Mode Baseline`, then `Mutate`, then `Restore` with the same new attempt label:

```powershell
./scripts/Invoke-LabTimed.ps1 -FilePath pwsh -Arguments @('-NoProfile', '-File', './scripts/Test-LabFreshness.ps1', '-Mode', 'Baseline', '-Attempt', 'freshnessV1')
./scripts/Test-LabFreshness.ps1 -Mode Baseline -Attempt freshnessV1 -CheckRun
```

Notebook creation can return HTTP 202. In that case, reconcile its operation from the private item journal before invoking the same phase again to start the existing notebook. Once a job is submitted, use only `-CheckRun` until it is terminal; require `Completed` before testing answers or advancing to the next phase. Respect `Retry-After`, bound each activity to 20 minutes, and inspect remote state after a local timeout. Do not restart an uncertain mutation.

Do not change or republish the ontology snapshot between phases. Run `VerifySnapshot` before and after the experiment and compare hashes. Always restore the fixture after the changed-data test. The default question suite intentionally retains the original 55-minute oracle: during `Mutate`, its nonzero exit is an expected negative control only when Q04 independently matches 92, the other three answers pass, and the recorded error is the answer assertion rather than a service failure.

## Reproduction Design

Use a synthetic maintenance scenario with `Machine` and `Anomaly` entities. A machine has zero or more anomalies. Define an actionable anomaly as `severity = critical AND status = open`. Bind the Gen2 ontology to the lakehouse tables and record each agent configuration before comparing results. Include a machine without anomalies and a closed critical anomaly to detect incorrect joins and filters.

| Test | Procedure | Evidence Required | Current Status |
| --- | --- | --- | --- |
| P01 | List Fabric capacities using the CLI identity | Successful API response | Passed |
| B01 | Query synthetic source tables directly | Counts and row identifiers matching the fixture | Spark fixture assertions passed; SQL endpoint queries not run |
| R01 | Add Gen2 through the SDK-equivalent public REST request | Confirmed generation, terminal operation and error | Failed in three configurations with the same schema error |
| G01 | Read Gen2 entities through Ontology MCP | Entities, keys, properties and bindings | Passed |
| G02 | Query Gen2 through native `ask_ontology` | Correct answers | 0/4; definition-loading failure |
| W01 | Test Gen1 | Old JSON definition and native attachment | Not pursued; outside current focus |
| W02 | Synchronize exported Gen2 context into a Lakehouse-backed Data Agent | Snapshot provenance and correct answers | 4/4 in each of two runs; native attachment absent; execution traces not captured |
| W03 | Change one synthetic value, query again, restore and query again without republishing | Independent source assertions, unchanged context hash and phase-specific answers | Passed: 55 / 92 / 55 minutes; all four answers correct in each phase |
| V01 | Compare published agent and source instructions with the current Gen2 export | Exact instruction equality, single Lakehouse source, selected tables and matching before/after hashes | Passed |
| V02 | Run the baseline oracle against changed data | Nonzero exit for answer mismatch, not a service failure | Passed: 92 correctly rejected against the stale 55 oracle |

The fixed questions ask for machines with actionable anomalies, actionable-anomaly count, machines with no anomalies, and downtime for open critical anomalies. Capture attachment success separately from query execution and answer correctness. Preflight and integration results are separate test gates.

## Workaround Limits

The tested bypass reads the real Gen2 TMDL definition instead of hand-authoring a duplicate business rule. It retains Gen2 as the source of context, but copies that context into Data Agent instructions. It does **not** retain a live native ontology connection, automatic refresh, or complete ontology governance semantics. After an ontology change, explicitly resynchronize and republish using a new reviewed attempt label. Neither oracle answers nor data rows are embedded in the instructions.

MCP returned answer text and conceptual query explanations, not server execution traces. Correct answers were checked against the seeded fixture; native generated SQL and run steps remain unverified. The matching texts must not be advertised as proof that native Gen2 integration works.

The automatically created Gen2 GraphModel contained no node or edge schema and no data sources. Official graph materialization requires opting in through the ontology's **Manage graph** experience; this was not performed. Portal attachment, manual context refresh and ontology-managed graph materialization remain untested.

Before agent tests, verify the Fabric and Ontology item tenant switches and the applicable Copilot/data-agent settings with an administrator. Do not automatically enable tenant-wide or cross-geography switches. Sweden Central is within the EU data boundary; evaluate the current documentation instead of enabling cross-geo processing indiscriminately.

## Costs and Cleanup

An active F2 is billable. Suspend it while blocked or between test sessions. Resolve the capacity resource ID from this lab's deployment outputs, verify its project tag, then use the documented ARM `suspend` or `resume` operation. A suspended capacity cannot execute the test. Suspending compute does not delete stored data or necessarily eliminate every storage charge.

Resume an existing lab capacity without redeploying infrastructure:

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $PWD '.azure'
$capacityId = az deployment group show --resource-group rg-fabric-ontology-gen2-lab --name ontology-gen2-capacity --query properties.outputs.capacityResourceId.value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $capacityId) { throw 'Cannot resolve the lab deployment.' }
$capacity = az rest --method get --url "https://management.azure.com${capacityId}?api-version=2023-11-01" -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $capacity.tags.project -ne 'fabric-ontology-gen2-lab') { throw 'Capacity ownership check failed.' }
if ($capacity.properties.state -ne 'Paused') { throw 'Inspect current capacity state before resuming.' }
az rest --method post --url "https://management.azure.com${capacityId}/resume?api-version=2023-11-01"
az rest --method get --url "https://management.azure.com${capacityId}?api-version=2023-11-01" --query '{state:properties.state,provisioning:properties.provisioningState}' -o json
```

Resume is asynchronous. Confirm `Active` and `Succeeded` with a later GET before executing tests; an accepted POST is not completion evidence.

Deleting a resource group does not delete separately managed Fabric workspaces and items. When those exist, remove only the lab-owned Fabric items/workspace first, then delete the dedicated Azure resources after explicit confirmation.

## References

- [Ontology overview and migration](https://learn.microsoft.com/fabric/iq/ontology/overview#migrate-from-old-experience).
- [Old JSON ontology definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-old-definition).
- [New ontology definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/ontology-definition).
- [Use Ontology as context in a Fabric data agent](https://learn.microsoft.com/fabric/data-science/data-agent-ontology-sources).
- [Fabric Data Agent Python SDK](https://learn.microsoft.com/fabric/data-science/fabric-data-agent-sdk).
- [Use Ontology MCP Server](https://learn.microsoft.com/fabric/iq/ontology/how-to-use-ontology-mcp-server).
- [Materialize an ontology graph](https://learn.microsoft.com/fabric/iq/ontology/how-to-use-ontology-graph).
- [Data agent prerequisites](https://learn.microsoft.com/fabric/data-science/how-to-create-data-agent).
- [Data agent tenant settings](https://learn.microsoft.com/fabric/data-science/data-agent-tenant-settings).
- [Fabric capacity Bicep reference](https://learn.microsoft.com/azure/templates/microsoft.fabric/2023-11-01/capacities).

Documentation links were checked on 2026-10-05. This repository contains original test design and links, not copies of third-party documentation.
