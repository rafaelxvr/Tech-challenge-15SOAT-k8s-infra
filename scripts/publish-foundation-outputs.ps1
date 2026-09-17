[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$TerraformOutputFile,

    [Parameter(Mandatory, ParameterSetName = 'Terraform')]
    [string]$TerraformDirectory,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$SourceCommit,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string]$ArtifactBucket,

    [Parameter(Mandatory)]
    [string]$ReceiptFile,

    # Offline mode is only for contract tests. It models immutable S3 versions
    # by writing each artifact under its generated VersionId.
    [switch]$Offline,
    [string]$OfflineDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { throw "Foundation output publication failed: $Message" }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

if ($Offline -and [string]::IsNullOrWhiteSpace($OfflineDirectory)) { Fail 'offline publication requires OfflineDirectory.' }
if ($PSCmdlet.ParameterSetName -eq 'File' -and -not (Test-Path -LiteralPath $TerraformOutputFile -PathType Leaf)) { Fail 'Terraform output file does not exist.' }
if ($PSCmdlet.ParameterSetName -eq 'Terraform' -and -not (Test-Path -LiteralPath $TerraformDirectory -PathType Container)) { Fail 'Terraform directory does not exist.' }

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactPath = Join-Path ([System.IO.Path]::GetTempPath()) ("oficina-foundation-outputs-$SourceCommit-$([guid]::NewGuid()).json")
try {
    $exportArguments = @{
        Scope = 'foundation'; Environment = 'foundation'; SourceCommit = $SourceCommit; OutputFile = $artifactPath
    }
    if ($PSCmdlet.ParameterSetName -eq 'File') { $exportArguments.TerraformOutputFile = $TerraformOutputFile }
    else { $exportArguments.TerraformDirectory = $TerraformDirectory }
    & (Join-Path $repoRoot 'scripts/export-outputs.ps1') @exportArguments | Out-Null
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { Fail 'output exporter did not write an artifact.' }

    $artifactKey = "releases/k8s/foundation/outputs/$SourceCommit.json"
    $artifactSha = Hash $artifactPath
    if ($Offline) {
        $versions = Join-Path $OfflineDirectory 'versions'
        New-Item -ItemType Directory -Path $versions -Force | Out-Null
        $versionId = "offline-$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $artifactPath -Destination (Join-Path $versions "$versionId.json")
    }
    else {
        $upload = & aws s3api put-object --bucket $ArtifactBucket --key $artifactKey --body $artifactPath --output json 2>$null
        if ($LASTEXITCODE -ne 0) { Fail 'versioned foundation-output upload failed.' }
        try { $versionId = [string](($upload | ConvertFrom-Json).VersionId) }
        catch { Fail 'foundation-output upload did not return JSON.' }
        if ([string]::IsNullOrWhiteSpace($versionId)) { Fail 'foundation-output upload returned no S3 VersionId.' }
    }

    $receipt = [ordered]@{
        schemaVersion     = 1
        kind              = 'foundation-output'
        artifactBucket    = $ArtifactBucket
        artifactKey       = $artifactKey
        artifactVersionId = $versionId
        artifactSha256    = $artifactSha
        sourceCommit      = $SourceCommit
        environment       = 'foundation'
        publishedAtUtc    = [datetime]::UtcNow.ToString('o')
    }
    $destination = Split-Path -Parent $ReceiptFile
    if ($destination -and -not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReceiptFile -NoNewline
    Write-Output 'Versioned foundation output artifact was published.'
}
finally { Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue }
