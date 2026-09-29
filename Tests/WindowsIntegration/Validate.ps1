param([string]$OutputDirectory = '.build/windows-transports')

$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$source = $repository
$revision = git -C $repository rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify MCP source revision' }
$output = Join-Path $repository $OutputDirectory
if (Test-Path $output) { throw 'Use a fresh native validation output directory' }
New-Item -ItemType Directory -Path $output | Out-Null
$output = (Resolve-Path $output).Path
$consumer = Join-Path $output 'consumer'
$evidence = Join-Path $output 'evidence'
New-Item -ItemType Directory -Path $consumer, $evidence | Out-Null
$sourceLock = Join-Path $source 'Package.resolved'
$sourceLockHash = (Get-FileHash $sourceLock -Algorithm SHA256).Hash
Copy-Item $sourceLock (Join-Path $evidence 'source-Package.resolved')
$revision | Set-Content (Join-Path $evidence 'source-revision.txt')
swift --version | Out-File (Join-Path $evidence 'toolchain.txt')
if ($LASTEXITCODE -ne 0) { throw 'Swift toolchain unavailable' }

$manifest = (Get-Content (Join-Path $PSScriptRoot 'Package.swift.template') -Raw).Replace(
    '__MCP_SOURCE__', $source.Replace('\', '/'))
$manifest | Set-Content (Join-Path $consumer 'Package.swift')
Copy-Item (Join-Path $source 'Package.resolved') (Join-Path $consumer 'Package.resolved')
$testDirectory = Join-Path $consumer 'Tests'
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testSources = @('InMemoryTransportTests.swift', 'WindowsStdioTransportTests.swift', 'ValueIntegerTests.swift')
$testHashes = foreach ($name in $testSources) {
    $original = Join-Path $source "Tests/MCPTests/$name"
    $copy = Join-Path $testDirectory $name
    Copy-Item $original $copy
    $hash = (Get-FileHash $original -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-FileHash $copy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Test source copy changed' }
    [pscustomobject]@{ path = "Tests/MCPTests/$name"; sha256 = $hash }
}
$testHashes | ConvertTo-Json | Set-Content (Join-Path $evidence 'upstream-test-sources.json')
Copy-Item (Join-Path $PSScriptRoot 'HTTPTransportTests.swift') $testDirectory

$developer = Split-Path (Split-Path $env:SDKROOT.TrimEnd([char[]]'\/'))
$testing = Join-Path $developer 'Library/Testing-6.2.3/usr/bin64'
$xctest = Join-Path $developer 'Library/XCTest-6.2.3/usr/bin64'
if (!(Test-Path (Join-Path $testing 'Testing.dll'))) { throw 'Missing SDK Testing runtime' }
if (!(Test-Path (Join-Path $xctest 'XCTest.dll'))) { throw 'Missing SDK XCTest runtime' }
$previousPath = $env:PATH
$env:PATH = "$testing;$xctest;$env:PATH"
$ready = Join-Path $evidence 'http-endpoint.txt'
$server = [System.Diagnostics.Process]::new()
$server.StartInfo.FileName = 'python'
$server.StartInfo.UseShellExecute = $false
$server.StartInfo.RedirectStandardError = $true
$server.StartInfo.ArgumentList.Add((Join-Path $PSScriptRoot 'http_fixture.py'))
$server.StartInfo.ArgumentList.Add('--ready-file')
$server.StartInfo.ArgumentList.Add($ready)
$previousEndpoint = $env:MCP_HTTP_FIXTURE_ENDPOINT
$results = @()
$started = $false
try {
    $started = $server.Start()
    if (!$started) { throw 'HTTP fixture failed to start' }
    $startup = [System.Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path $ready)) {
        if ($server.HasExited -or $startup.Elapsed.TotalSeconds -gt 10) {
            [pscustomobject]@{
                hasExited = $server.HasExited
                exitCode = $(if ($server.HasExited) { $server.ExitCode } else { $null })
                elapsedMilliseconds = $startup.ElapsedMilliseconds
            } | ConvertTo-Json | Set-Content (Join-Path $evidence 'http-startup-failure.json')
            throw 'HTTP fixture was not ready'
        }
        Start-Sleep -Milliseconds 20
    }
    $env:MCP_HTTP_FIXTURE_ENDPOINT = Get-Content $ready -Raw
    foreach ($configuration in @('debug', 'release')) {
        $log = Join-Path $evidence "$configuration-tests.log"
        swift test --package-path $consumer --no-parallel -c $configuration *> $log
        $testCode = $LASTEXITCODE
        Get-Content $log -Tail 60
        $results += [pscustomobject]@{ configuration = $configuration; testExitCode = $testCode }
        [pscustomobject]@{ sourceRevision = $revision; results = $results } |
            ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'results.json')
    }
} finally {
    $env:MCP_HTTP_FIXTURE_ENDPOINT = $previousEndpoint
    $env:PATH = $previousPath
    if ($started -and !$server.HasExited) { $server.Kill() }
    if ($started) {
        if (!$server.WaitForExit(5000)) { throw 'Owned HTTP fixture did not exit' }
        $server.StandardError.ReadToEnd() | Out-File (Join-Path $evidence 'http-server-stderr.log')
    }
    $server.Dispose()
}
if (Test-Path (Join-Path $consumer 'Package.resolved')) {
    Copy-Item (Join-Path $consumer 'Package.resolved') (Join-Path $evidence 'consumer-Package.resolved')
}
if ((Get-FileHash $sourceLock -Algorithm SHA256).Hash -ne $sourceLockHash) {
    throw 'The source dependency lock changed during consumer validation'
}
if ($results.Where({ $_.testExitCode -ne 0 }).Count -gt 0) { exit 1 }

