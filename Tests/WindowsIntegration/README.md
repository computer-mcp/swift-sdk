# Native Windows transport validation

With Swift 6.2.3 and Python available, run from the repository root:

```powershell
./Tests/WindowsIntegration/Validate.ps1
```

The disposable consumer imports this checkout's complete MCP library and copies
the owning in-memory, Windows stdio and JSON integer tests without changing their bytes.
A loopback HTTP peer supplies real native requests and session responses. Debug
and release configurations cover transport state, exact integers, UTF-8 framing,
bounded queues, backpressure, cancellation, joined shutdown and caller-owned
descriptor preservation. The creating process joins the HTTP peer on exit.
Request and response decoding reject integers outside the platform's signed Int
range before a floating-point fallback can round them; supported integer and
fractional values retain their existing wire representation.

The consumer starts with the repository's dependency lock and retains its resolved
lock, source/test identities, logs and results under `.build/windows-transports`.
The source lock must remain unchanged. This gate does not apply patches or change
the source dependency graph. It covers these native library transports, not
every upstream executable, SSE support or model authentication.
