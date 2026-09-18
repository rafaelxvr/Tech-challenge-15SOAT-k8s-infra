Set-StrictMode -Version Latest

function Read-PlatformManifest([string]$Path) {
    $text=[IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '\$\{[^}]+\}') { throw 'Platform manifest must be resolved and nonempty.' }
    # Terraform is already pinned by this repository. An isolated, empty console
    # directory provides yamldecode without providers, backend, kubeconfig or AWS.
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('oficina-platform-decode-'+[guid]::NewGuid())
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $scratch 'platform.yaml'),$text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
        $expression='jsonencode([for doc in split("\n---\n", file("platform.yaml")) : yamldecode(doc) if trimspace(doc) != ""])'
        $encoded=$expression | & terraform "-chdir=$scratch" console -no-color 2>&1
        if($LASTEXITCODE -ne 0){throw 'Platform YAML decoding failed.'}
        $json=ConvertFrom-Json -InputObject ($encoded -join "`n") -NoEnumerate
        $documents=ConvertFrom-Json -InputObject $json -NoEnumerate
        if($documents -isnot [array] -or $documents.Count -eq 0){throw 'Platform manifest has no documents.'}
        return ,$documents
    } catch { throw 'Platform manifest could not be decoded offline.' }
    finally {
        $resolved=[IO.Path]::GetFullPath($scratch)
        if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('oficina-platform-decode-')){throw 'Unsafe cleanup target.'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function ConvertTo-OrderedPlatformValue([object]$Value) {
    if($null -eq $Value){return $null}
    if($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary]) {
        $keys=[string[]]@(if($Value -is [pscustomobject]){$Value.PSObject.Properties | ForEach-Object Name}else{$Value.Keys})
        [Array]::Sort($keys,[StringComparer]::Ordinal)
        $result=[ordered]@{}
        foreach($key in $keys){$result[$key]=ConvertTo-OrderedPlatformValue $Value.$key}
        return $result
    }
    if($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-OrderedPlatformValue $_ }) }
    return $Value
}

function Write-OrderedPlatformJson([object]$Value,[string]$Path) {
    $json=ConvertTo-OrderedPlatformValue $Value | ConvertTo-Json -Depth 70 -Compress
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$json,[Text.UTF8Encoding]::new($false))
}
