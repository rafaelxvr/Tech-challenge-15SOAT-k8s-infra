$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$foundationRoot = Split-Path -Parent $PSScriptRoot
$terraform = Get-Content -Raw -LiteralPath (Join-Path $foundationRoot 'main.tf')

foreach ($name in @('internal_alb', 'vpc_link', 'lambda', 'rds')) {
    $escapedName = [regex]::Escape($name)
    $match = [regex]::Match($terraform, "(?s)resource\s+`"aws_security_group`"\s+`"$escapedName`"\s*\{(.*?)\n\}")
    if (-not $match.Success) { throw "Expected foundation security group '$name' was not found." }
    if ($match.Groups[1].Value -match '(?m)^\s*(ingress|egress)\s*=') {
        throw "Security group '$name' must not mix inline ingress/egress with standalone rule resources."
    }
    if ($terraform -notmatch [regex]::Escape("security_group_id            = aws_security_group.$name.id") -and $terraform -notmatch [regex]::Escape("security_group_id = aws_security_group.$name.id") -and $terraform -notmatch [regex]::Escape("referenced_security_group_id = aws_security_group.$name.id")) {
        throw "Security group '$name' must retain standalone rule ownership."
    }
}

Write-Output 'foundation security-group rule ownership contract: PASS'
