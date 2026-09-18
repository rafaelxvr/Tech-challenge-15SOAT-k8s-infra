[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$repo=Split-Path -Parent $PSScriptRoot
$dockerfile=Get-Content -LiteralPath "$repo/images/deployer/Dockerfile" -Raw
$script:checks=0
function Assert([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
$tools=@(
    @{Name='POWERSHELL';Archive='/tmp/powershell.rpm';Install='dnf -y install /tmp/powershell.rpm'},
    @{Name='AWS_CLI';Archive='/tmp/awscliv2.zip';Install='unzip -q /tmp/awscliv2.zip'},
    @{Name='TERRAFORM';Archive='/tmp/terraform.zip';Install='unzip -q /tmp/terraform.zip'},
    @{Name='KUBECTL';Archive='/usr/local/bin/kubectl';Install='chmod 0755 /usr/local/bin/kubectl'},
    @{Name='HELM';Archive='/tmp/helm.tgz';Install='tar -xzf /tmp/helm.tgz'}
)
foreach($tool in $tools) {
    Assert ($dockerfile -match ('(?m)^ARG '+$tool.Name+'_SHA256\r?$')) "Missing mandatory checksum input for $($tool.Name)."
    $verification='/bin/sh /usr/local/bin/verify-deployer-sha256 "${'+$tool.Name+'_SHA256}" '+$tool.Archive
    $download=$dockerfile.IndexOf(' -o '+$tool.Archive+' ')
    $verify=$dockerfile.IndexOf($verification)
    $install=$dockerfile.IndexOf($tool.Install)
    Assert ($download -ge 0 -and $verify -gt $download -and $install -gt $verify) "Download must be verified before use: $($tool.Name)."
}
Assert ($dockerfile.IndexOf('for checksum in') -lt $dockerfile.IndexOf('RUN dnf')) 'All checksum inputs must be validated before any package/download operation.'
Assert ($dockerfile.Contains('verify-deployer-sha256 "$checksum" || exit 1')) 'Missing or invalid checksum must abort the preflight RUN.'
Assert ($dockerfile -match '(?m)^FROM amazonlinux@sha256:[a-f0-9]{64}\r?$') 'Base image must stay digest-pinned.'
$shell=if($IsWindows){Join-Path (Split-Path -Parent (Get-Command git -ErrorAction Stop).Source) '../bin/bash.exe'}else{(Get-Command sh -ErrorAction Stop).Source}
if(-not (Test-Path -LiteralPath $shell)){throw 'A local POSIX shell is required for the checksum contract test.'}
$verifier=([IO.Path]::GetFullPath("$repo/images/deployer/verify-sha256.sh")).Replace('\','/')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('oficina-deployer-checksums-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $archive=Join-Path $temp 'fixture archive.bin'
    [IO.File]::WriteAllBytes($archive,[byte[]](0,1,2,3,254,255))
    $digest=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    & $shell $verifier $digest ($archive.Replace('\','/')) 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Matching bytes must pass actual sha256sum verification.'
    & $shell $verifier $digest 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Explicit valid digest must pass syntax preflight.'
    foreach($invalid in @('', 'pending', ('a'*63), ('A'*64), ('z'*64), ($digest+"`n"), ('0'*64))) {
        & $shell $verifier $invalid ($archive.Replace('\','/')) 2>&1 | Out-Null
        Assert ($LASTEXITCODE -ne 0) 'Invalid or mismatched checksum must fail closed.'
    }
    [IO.File]::WriteAllBytes($archive,[byte[]](0,1,2,3,254,254))
    & $shell $verifier $digest ($archive.Replace('\','/')) 2>&1 | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'One-byte corruption must fail before installation.'
    & $shell $verifier $digest ((Join-Path $temp 'missing.zip').Replace('\','/')) 2>&1 | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'Missing downloaded file must fail closed.'
    $workflow=Get-Content -LiteralPath "$repo/.github/workflows/ci-cd.yml" -Raw
    Assert ($workflow.Contains('./tests/deployer-dependencies-tests.ps1')) 'CI must execute the offline dependency contract.'
    Write-Output "PASS: $script:checks deployer dependency assertions; local checksum fixtures only, no download/build/push."
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-deployer-checksums-')){throw 'Unsafe cleanup target.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
