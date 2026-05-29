# Dispatches a GitHub Actions workflow on a target repository as the
# aspire-repo-bot GitHub App. By default, polls the resulting run until it
# completes and exits 0 only if the dispatched run concludes with 'success'.
# With -NoWait, dispatches and exits 0 immediately without resolving or
# polling the run (fire-and-forget).
#
# This script is invoked from AzDO release pipelines to trigger downstream
# GitHub Actions workflows (e.g. release-github-tasks.yml after a GA release,
# validate-published-build.yml after a staging/release publish). It centralizes
# workflow dispatch, run-id resolution, and run polling so the pipeline YAML
# stays declarative.
#
# Authentication (mint a GitHub App installation access token) is delegated to
# Get-AspireBotInstallationToken.ps1 so the same flow can be reused by other
# release pipeline scripts (e.g. publish-release-cli-assets.ps1).
#
# Dispatch + correlation flow (per GitHub API docs):
#   https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app
#   1. POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches with the installation token.
#   2. (wait mode only) Poll GET /repos/.../actions/runs filtered by workflow + branch to find the
#      run we just queued (workflow_dispatch does not return a run id directly — this is the
#      documented workaround).
#   3. (wait mode only) Poll the run until status=completed; succeed only if conclusion=success.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][string]$PrivateKeyPem,
    [Parameter(Mandatory = $true)][string]$Owner,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$WorkflowFile,
    [Parameter(Mandatory = $true)][string]$Ref,
    [Parameter(Mandatory = $true)][hashtable]$Inputs,
    [Parameter()][int]$PollIntervalSeconds = 30,
    [Parameter()][int]$PollTimeoutMinutes = 60,
    # When set, dispatch and exit immediately without resolving the dispatched run id or
    # polling for completion. The caller treats the GH workflow as informational signal
    # rather than a gate. Use when the dispatching pipeline should not block on (or fail
    # because of) the downstream workflow.
    [Parameter()][switch]$NoWait
)

$ErrorActionPreference = 'Stop'

function Invoke-GitHubApi {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Token,
        [object]$Body
    )

    $headers = @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'aspire-release-pipeline'
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }

    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 8 -Compress)
        $params['ContentType'] = 'application/json'
    }

    return Invoke-RestMethod @params
}

Write-Host "=== Dispatch Release GitHub Tasks ==="
Write-Host "Target: $Owner/$Repo workflow=$WorkflowFile ref=$Ref"
Write-Host "Inputs:"
foreach ($key in $Inputs.Keys) {
    Write-Host "  $key = $($Inputs[$key])"
}

# Mint an installation access token via the shared helper (handles JWT mint,
# installation id lookup, and token exchange).
$tokenScript = Join-Path $PSScriptRoot 'Get-AspireBotInstallationToken.ps1'
$installationToken = & $tokenScript -AppId $AppId -PrivateKeyPem $PrivateKeyPem -Owner $Owner -Repo $Repo
if ([string]::IsNullOrWhiteSpace($installationToken)) {
    Write-Error "Failed to acquire installation access token from Get-AspireBotInstallationToken.ps1"
    exit 1
}

# Record the time *before* dispatching so we can find the resulting run reliably.
# GitHub's workflow_dispatch endpoint returns 204 with no body — there is no run id
# in the response. The standard workaround is to filter actions/runs by event,
# workflow, branch, and a created>=<dispatch time> timestamp.
$dispatchedAt = [DateTimeOffset]::UtcNow

# Dispatch the workflow.
Write-Host "Dispatching workflow $WorkflowFile on ref=$Ref..."
$dispatchBody = @{
    ref    = $Ref
    inputs = $Inputs
}
Invoke-GitHubApi -Method POST `
    -Uri "https://api.github.com/repos/$Owner/$Repo/actions/workflows/$WorkflowFile/dispatches" `
    -Token $installationToken `
    -Body $dispatchBody | Out-Null
Write-Host "✓ Workflow dispatch accepted."

if ($NoWait) {
    # Fire-and-forget: don't try to resolve a run id or poll. Surface a link to the
    # workflow runs page so operators can find the dispatched run manually.
    $runsListUrl = "https://github.com/$Owner/$Repo/actions/workflows/$WorkflowFile"
    Write-Host "##[section]Dispatched (no wait). See recent runs: $runsListUrl"
    Write-Host "##vso[task.setvariable variable=DispatchedRunsUrl]$runsListUrl"
    exit 0
}

# Resolve the run id. The dispatched run is not always queryable instantly,
# so retry for up to 2 minutes. Filter by created>=dispatchedAt-30s to allow for
# clock skew between this runner and GitHub.
$createdFilter = $dispatchedAt.AddSeconds(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')
$runId = $null
$runHtmlUrl = $null
$resolveDeadline = [DateTime]::UtcNow.AddMinutes(2)

while ([DateTime]::UtcNow -lt $resolveDeadline -and -not $runId) {
    Start-Sleep -Seconds 5
    $runsUri = "https://api.github.com/repos/$Owner/$Repo/actions/workflows/$WorkflowFile/runs?event=workflow_dispatch&branch=$([Uri]::EscapeDataString($Ref))&created=%3E%3D$createdFilter&per_page=10"
    try {
        $runs = Invoke-GitHubApi -Method GET -Uri $runsUri -Token $installationToken
    }
    catch {
        Write-Host "  (transient) Could not list runs yet: $($_.Exception.Message)"
        continue
    }

    if ($runs.workflow_runs -and $runs.workflow_runs.Count -gt 0) {
        # The list endpoint returns runs newest first. We pick the newest run
        # that satisfies the created>=dispatchedAt-30s filter — the dispatch we
        # just issued is by definition the most recent qualifying run on this
        # branch+workflow. Picking the oldest qualifying run would attach us
        # to an earlier dispatch within the clock-skew window (e.g. a quick
        # re-run of this AzDO stage).
        $candidate = $runs.workflow_runs | Sort-Object -Property created_at -Descending | Select-Object -First 1
        $runId = $candidate.id
        $runHtmlUrl = $candidate.html_url
        Write-Host "✓ Resolved dispatched run: $runHtmlUrl (id=$runId)"
        break
    }

    Write-Host "  Waiting for dispatched run to appear..."
}

if (-not $runId) {
    Write-Error "Could not resolve the dispatched workflow run within 2 minutes. Check the workflow run history manually."
    exit 1
}

# Surface the run URL in the AzDO job summary regardless of outcome.
Write-Host "##vso[task.setvariable variable=DispatchedRunUrl]$runHtmlUrl"
Write-Host "##[section]Dispatched run: $runHtmlUrl"

# Poll the run until it reaches a terminal state.
$pollDeadline = [DateTime]::UtcNow.AddMinutes($PollTimeoutMinutes)
$status = $null
$conclusion = $null

while ([DateTime]::UtcNow -lt $pollDeadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    try {
        $run = Invoke-GitHubApi -Method GET -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs/$runId" -Token $installationToken
    }
    catch {
        Write-Host "  (transient) Poll failed: $($_.Exception.Message). Retrying."
        continue
    }

    $status = $run.status
    $conclusion = $run.conclusion
    Write-Host "  status=$status conclusion=$conclusion"

    if ($status -eq 'completed') {
        break
    }
}

if ($status -ne 'completed') {
    Write-Error "Dispatched workflow did not complete within $PollTimeoutMinutes minutes. Last status: $status. See $runHtmlUrl"
    exit 1
}

if ($conclusion -ne 'success') {
    Write-Error "Dispatched workflow finished with conclusion '$conclusion'. See $runHtmlUrl"
    exit 1
}

Write-Host "✓ Dispatched workflow completed successfully: $runHtmlUrl"
exit 0
