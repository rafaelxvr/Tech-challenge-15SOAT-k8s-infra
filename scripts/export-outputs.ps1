[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$TerraformOutputFile,

    [Parameter(Mandatory, ParameterSetName = 'Terraform')]
    [string]$TerraformDirectory,

    [Parameter(Mandatory)]
    [ValidateSet('foundation', 'environment')]
    [string]$Scope,

    [Parameter(Mandatory)]
    [ValidateSet('staging', 'production', 'foundation')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$SourceCommit,

    [string]$AllowlistFile = (Join-Path $PSScriptRoot '../contracts/outputs-allowlist.json'),

    [Parameter(Mandatory)]
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Output export failed: $Message" }
function Is-Forbidden([string]$Name) { return $Name -match '(?i)(secret|password|credential|token|state|master)' }

if (-not (Test-Path -LiteralPath $AllowlistFile -PathType Leaf)) { Fail 'allowlist file does not exist.' }
try { $allowlist = Get-Content -LiteralPath $AllowlistFile -Raw | ConvertFrom-Json }
catch { Fail 'allowlist is not valid JSON.' }
if ($allowlist.schemaVersion -ne 1 -or $allowlist.repository -ne 'oficina-k8s-infra') { Fail 'allowlist has an unsupported schema or owner.' }
$scopeProperty = $allowlist.scopes.PSObject.Properties[$Scope]
if ($null -eq $scopeProperty) { Fail "allowlist does not define scope '$Scope'." }

if ($PSCmdlet.ParameterSetName -eq 'Terraform') {
    if (-not (Test-Path -LiteralPath $TerraformDirectory -PathType Container)) { Fail 'Terraform directory does not exist.' }
    $raw = & terraform -chdir=$TerraformDirectory output -json
    if ($LASTEXITCODE -ne 0) { Fail 'terraform output did not succeed.' }
}
else {
    if (-not (Test-Path -LiteralPath $TerraformOutputFile -PathType Leaf)) { Fail 'Terraform output file does not exist.' }
    $raw = Get-Content -LiteralPath $TerraformOutputFile -Raw
}
try { $terraformOutputs = $raw | ConvertFrom-Json }
catch { Fail 'Terraform output is not valid JSON.' }

$published = [ordered]@{}
foreach ($mapping in $scopeProperty.Value.PSObject.Properties) {
    $publicField = [string]$mapping.Name
    $terraformField = [string]$mapping.Value
    if (Is-Forbidden $publicField -or Is-Forbidden $terraformField) { Fail "allowlist contains forbidden output '$publicField'." }
    $candidate = $terraformOutputs.PSObject.Properties[$terraformField]
    if ($null -eq $candidate) { continue }
    $valueProperty = $candidate.Value.PSObject.Properties['value']
    $published[$publicField] = if ($null -eq $valueProperty) { $candidate.Value } else { $valueProperty.Value }
}
if ($published.Count -eq 0) { Fail "Terraform output contains no allowlisted values for '$Scope'." }

$document = [ordered]@{
    schemaVersion = 1
    environment   = $Environment
    sourceCommit  = $SourceCommit
    outputs       = $published
}
$destination = Split-Path -Parent $OutputFile
if ($destination -and -not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }
$document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -NoNewline
Write-Output 'Allowlisted Terraform outputs were exported.'
