#requires -Version 7.0

function Invoke-LabFabricRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^/v1/[A-Za-z0-9/?=&._%-]+$')][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [System.Collections.IDictionary]$Body,
        [string]$AzureConfigDirectory = (Join-Path $PSScriptRoot '../.azure'),
        [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '../.local/api')
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $previousConfig = $env:AZURE_CONFIG_DIR
    try {
        $env:AZURE_CONFIG_DIR = (Resolve-Path $AzureConfigDirectory).Path
        $tokenOutput = & az account get-access-token --resource https://api.fabric.microsoft.com --only-show-errors -o json 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Unable to obtain Fabric token from the selected Azure CLI cache.' }
        $token = ($tokenOutput -join "`n" | ConvertFrom-Json -AsHashtable).accessToken
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned an empty access token.' }
        $request = @{
            Uri = "https://api.fabric.microsoft.com$Path"
            Method = $Method
            Headers = @{ Authorization = "Bearer $token" }
            SkipHttpErrorCheck = $true
            MaximumRedirection = 0
            TimeoutSec = 90
        }
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $request.OperationTimeoutSeconds = 90
        }
        if ($null -ne $Body) {
            $request.ContentType = 'application/json; charset=utf-8'
            $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress))
        }
        $response = Invoke-WebRequest @request
        $content = [string]$response.Content
        $data = $null
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            try { $data = $content | ConvertFrom-Json -AsHashtable } catch { $data = @{ rawBody = $content } }
        }
        $headers = @{}
        foreach ($name in @('Location', 'Retry-After', 'x-ms-operation-id', 'requestId', 'x-ms-request-id')) {
            if ($response.Headers.ContainsKey($name)) { $headers[$name] = $response.Headers[$name] -join ',' }
        }
        $record = [ordered]@{
            checkedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            method = $Method
            path = $Path
            statusCode = [int]$response.StatusCode
            headers = $headers
            request = $Body
            data = $data
            elapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
        }
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
        $evidencePath = Join-Path $EvidenceDirectory "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid()).json"
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $evidencePath -Encoding utf8
        [pscustomobject]@{
            StatusCode = $record.statusCode
            Data = $data
            Headers = $headers
            EvidencePath = $evidencePath
            IsPending = $record.statusCode -eq 202
        }
    } finally {
        $token = $null
        $tokenOutput = $null
        $env:AZURE_CONFIG_DIR = $previousConfig
        Write-Host "Fabric $Method elapsed: $([math]::Round($timer.Elapsed.TotalSeconds, 1))s"
    }
}

function New-LabDefinitionPart {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    @{
        path = $Path
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        payloadType = 'InlineBase64'
    }
}