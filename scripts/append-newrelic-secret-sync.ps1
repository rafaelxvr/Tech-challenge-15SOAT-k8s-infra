[CmdletBinding()]
param([Parameter(Mandatory)] [string]$Manifest)

$ErrorActionPreference = 'Stop'
$chart = [Console]::In.ReadToEnd()
if ($Manifest -match '\$\{[A-Za-z_]+\}') { throw 'New Relic secret sync has unresolved deployment tokens.' }
[Console]::Out.Write($Manifest + "`n---`n" + $chart)
