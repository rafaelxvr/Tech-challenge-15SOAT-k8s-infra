[CmdletBinding()]
param(
    [string]$FunctionsRoot = 'D:/repository/oficina-functions',
    [string]$JavaHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$module = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/modules/functions/main.tf') -Raw
$funDocs = Get-Content -LiteralPath (Join-Path $FunctionsRoot 'docs/token-trust.md') -Raw

function Assert-Contains([string]$Text, [string]$Expected, [string]$Message) {
    if (-not $Text.Contains($Expected)) { throw $Message }
}
function Merge-Environment([hashtable[]]$Maps) {
    $result = @{}
    foreach ($map in $Maps) {
        foreach ($pair in $map.GetEnumerator()) { $result[$pair.Key] = $pair.Value }
    }
    return $result
}

foreach ($setting in @('DATABASE_SECRET_ARN', 'CUSTOMER_SIGNING_SECRET_ARN', 'AUTHORIZER_TRUST_SECRET_ARN', 'RDS_CA_CERT_SECRET_ARN', '/tmp/oficina/rds-ca.pem')) {
    Assert-Contains $funDocs $setting "FUN resolver contract is missing $setting."
    Assert-Contains $module $setting "I5 must configure declared FUN resolver setting $setting."
}
foreach ($legacy in @('AUTH_LOOKUP_SECRET_ARN', 'NOTIFICATION_LOOKUP_SECRET_ARN', 'CUSTOMER_SIGNING_KEY_SECRET_ARN', 'CUSTOMER_PUBLIC_KEYS_SECRET_ARN', 'STAFF_HMAC_SECRET_ARN', 'DB_HOST                     =')) {
    if ($module.Contains($legacy)) { throw "I5 must not deploy stale/direct secret configuration: $legacy" }
}
if ($module -notmatch 'without\(System.getenv\(\), "CUSTOMER_SIGNING_SECRET_ARN"\)') {
    # This source-level check is performed below against FUN because the K8S module cannot prove its handler split itself.
    $factory = Get-Content -LiteralPath (Join-Path $FunctionsRoot 'src/main/java/com/oficina/functions/bootstrap/FunctionFactory.java') -Raw
    Assert-Contains $factory 'without(System.getenv(), "CUSTOMER_SIGNING_SECRET_ARN")' 'FUN challenge composition must exclude the signing-key resolver setting.'
}

if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    $candidates = Get-ChildItem -Directory 'C:/Program Files/Eclipse Adoptium' -ErrorAction SilentlyContinue | Where-Object Name -like 'jdk-17*' | Sort-Object Name -Descending
    if ($candidates) { $JavaHome = $candidates[0].FullName }
}
if ([string]::IsNullOrWhiteSpace($JavaHome)) { throw 'JavaHome must identify a Java 17 JDK.' }
$java = Join-Path $JavaHome 'bin/java.exe'
$javac = Join-Path $JavaHome 'bin/javac.exe'
if (-not (Test-Path -LiteralPath $java) -or -not (Test-Path -LiteralPath $javac)) { throw 'JavaHome must contain java.exe and javac.exe.' }
$version = & $java -version 2>&1 | Out-String
if ($version -notmatch '"17\.') { throw 'Cross-repository cold-start harness requires Java 17.' }

$mvn = Join-Path $FunctionsRoot 'mvnw.cmd'
if (-not (Test-Path -LiteralPath $mvn)) { throw 'FUN Maven wrapper is required.' }
$env:JAVA_HOME = $JavaHome
$classpathFile = Join-Path $FunctionsRoot 'target/i5-runtime-classpath.txt'
Push-Location $FunctionsRoot
try {
    & $mvn -q -DskipTests package
    if ($LASTEXITCODE -ne 0) { throw 'FUN package failed before cold-start verification.' }
    & $mvn -q dependency:build-classpath "-Dmdep.outputFile=$classpathFile"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $classpathFile)) { throw 'FUN runtime classpath generation failed.' }
}
finally {
    Pop-Location
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('oficina-i5-cold-start-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try {
    $runtimeClasspath = "$(Join-Path $FunctionsRoot 'target/classes');$((Get-Content -LiteralPath $classpathFile -Raw).Trim())"
    & $javac -encoding UTF-8 -cp $runtimeClasspath -d $temporary (Join-Path $repoRoot 'tests/interop/FunctionHandlerColdStart.java')
    if ($LASTEXITCODE -ne 0) { throw 'I5 cold-start harness compilation failed.' }

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = [Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey())
    $publicKey = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo())
    $caPath = Join-Path $temporary 'rds-ca.pem'
    Set-Content -LiteralPath $caPath -Value 'local test path; ARN resolver materialization is verified by FUN tests' -NoNewline

    $sharedDatabase = @{
        DB_HOST = 'localhost'; DB_PORT = '5432'; DB_NAME = 'oficina'; DB_USER = 'runtime'; DB_PASSWORD = 'test-password'; DB_CA_PATH = $caPath
    }
    $handlerConfigurations = @{
        'com.oficina.functions.handler.CriarDesafioHandler' = Merge-Environment @($sharedDatabase, @{ CHALLENGE_TABLE = 'challenge'; OTP_SENDER = 'no-reply@example.invalid' })
        'com.oficina.functions.handler.VerificarDesafioHandler' = Merge-Environment @($sharedDatabase, @{ CHALLENGE_TABLE = 'challenge'; CUSTOMER_PRIVATE_KEY_B64 = $privateKey; CUSTOMER_JWT_ISSUER = 'oficina-staging-customer'; CUSTOMER_JWT_AUDIENCE = 'oficina-staging-api'; CUSTOMER_KEY_ID = 'customer-2026-01' })
        'com.oficina.functions.handler.AuthorizerHandler' = @{ CUSTOMER_PUBLIC_KEY_B64 = $publicKey; STAFF_HMAC_SECRET = '01234567890123456789012345678901'; CUSTOMER_JWT_ISSUER = 'oficina-staging-customer'; CUSTOMER_JWT_AUDIENCE = 'oficina-staging-api'; CUSTOMER_KEY_ID = 'customer-2026-01'; STAFF_JWT_ISSUER = 'oficina-staging-staff'; STAFF_JWT_AUDIENCE = 'oficina-staging-api'; STAFF_KEY_ID = 'staff-2026-01' }
        'com.oficina.functions.handler.NotificacaoHandler' = Merge-Environment @($sharedDatabase, @{ DELIVERY_TABLE = 'delivery'; STATUS_SENDER = 'no-reply@example.invalid' })
    }

    foreach ($entry in $handlerConfigurations.GetEnumerator()) {
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $java
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.ArgumentList.Add('-cp')
        $psi.ArgumentList.Add("$temporary;$runtimeClasspath")
        $psi.ArgumentList.Add('com.oficina.iac.FunctionHandlerColdStart')
        $psi.ArgumentList.Add($entry.Key)
        foreach ($secretSetting in @('DATABASE_SECRET_ARN', 'CUSTOMER_SIGNING_SECRET_ARN', 'AUTHORIZER_TRUST_SECRET_ARN', 'RDS_CA_CERT_SECRET_ARN')) { [void]$psi.Environment.Remove($secretSetting) }
        $psi.Environment['AWS_REGION'] = 'us-east-1'
        $psi.Environment['AWS_DEFAULT_REGION'] = 'us-east-1'
        $psi.Environment['AWS_EC2_METADATA_DISABLED'] = 'true'
        foreach ($pair in $entry.Value.GetEnumerator()) { $psi.Environment[$pair.Key] = [string]$pair.Value }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not $stdout.Contains('PASS: zero-argument cold start')) {
            throw "FUN cold start failed for $($entry.Key): $stderr"
        }
        Write-Output $stdout.Trim()
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -Recurse }
}

Write-Output 'PASS: I5 ARN configuration matches FUN resolver declarations and all four zero-argument handlers cold-start with resolved values.'
