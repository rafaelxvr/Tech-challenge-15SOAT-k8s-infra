$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$foundation = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'infra/foundation/main.tf')
$root = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'infra/foundation-addons/main.tf')
$existingExecutor = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'infra/modules/deployment-executor/variables.tf')

if ($foundation -notmatch 'module "foundation_addons_executor"') { throw 'Foundation must instantiate the dedicated addons executor.' }
if ($foundation -match 'resource "helm_release"') { throw 'Foundation must not manage releases duplicated by the isolated addons root.' }
if (($root | Select-String -Pattern 'resource "helm_release"' -AllMatches).Matches.Count -ne 4) { throw 'The isolated root must own exactly four reviewed Helm releases.' }
if ($root -notmatch 'aws-load-balancer-controller"\s*version\s*=\s*"1\.12\.0"' -or $root -notmatch 'metrics-server"\s*version\s*=\s*"3\.12\.2"') { throw 'Foundation addon charts must remain pinned.' }
if ($existingExecutor -notmatch 'length\(var\.deployments\) == 8') { throw 'The foundation-addons executor must not weaken the existing eight-project application executor contract.' }

Write-Output 'foundation-addons path contract: PASS'
