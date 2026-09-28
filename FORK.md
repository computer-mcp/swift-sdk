# Transport fork

Computer MCP maintains this fork of
[modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk).
Its upstream base is release `0.12.1`, commit
`a0ae212ebf6eab5f754c3129608bc5557637e605`. The original source, product boundaries,
protocol definitions, copyright notices and license terms remain in this
repository. This fork is not an upstream release.

## Owned changes

The MCP transport layer owns the following behavior:

- HTTP client EventSource use is conditional on its supported Apple platforms;
  other platforms retain the existing non-EventSource HTTP path.
- Windows stdio owns duplicated native byte-pipe handles, incremental bounded
  framing, serialized writes and joined shutdown. Cancelling the receive producer
  closes its transport and wakes retained work.
- POSIX stdio serializes complete frames across concurrent senders, including
  partial writes and backpressure. Disconnect releases pending writers.

MCP declarations and client/server APIs remain upstream-owned. Vendor-specific
Codex App Server and Exec behavior belongs to swift-codex; host authorization
belongs to Computer MCP. These responsibilities are not implemented in this fork.

Windows support here covers the MCP library's exercised HTTP, in-memory and stdio
paths. It does not establish Windows support for every upstream executable or
transport dependency, nor does it imply SSE support through EventSource on
Windows. Platform validation must identify the actual product and transport.

## Adoption and validation

Downstream packages adopt an exact fetchable commit from
`https://github.com/computer-mcp/swift-sdk.git` and record it in their dependency
lock. A local source override or a patch applied during a test is not a shipping
dependency. Upstream tags retain their upstream identity; this fork does not
move or replace them.

Run `swift build` and `swift test` for the complete supported native package.
Transport regression coverage lives in `Tests/MCPTests`, including real Windows
pipe ownership and POSIX concurrent-write cases. Downstream native Windows jobs
also exercise complete standard MCP connections and process cleanup with the
exact dependency revision. A build or fixture success does not prove model
authentication or installed-application acceptance.

Reconcile future upstream changes against these transport invariants and rerun
the affected platform and downstream checks before advancing a consumer's pin.
The root `LICENSE` remains the authority for upstream licensing and its
transition terms; distribution must preserve applicable licenses and notices.
