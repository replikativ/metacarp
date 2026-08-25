# Meta-Carp CBOR session host

This is the native, deterministic-CBOR host for the transport-neutral
`carp-session` library. It accepts four-byte big-endian length-prefixed messages
on stdin/stdout and uses the source-only sibling `carp-cbor` package.

Requests are `[2, id, operation, payload]`; responses are
`[2, id, success?, payload]`. The host supports `ping`, `quit`, `reset`,
single-definition and whole-input upsert/removal, ownership analysis, and
rooted native-library emission. Library artifacts use format 2 and carry C,
the exact ownership plan used by lowering, and host-resolved include/link
inputs.

From adjacent `Meta-Carp`, `Carp`, and `carp-cbor` checkouts:

```sh
out/carp-compiler -b --optimize --core ../Carp/core \
  -o out/carp-session-server-cbor hosts/cbor/SessionServer.carp
```

Or run `scripts/build-cbor-host.sh`; `scripts/smoke-cbor-host.sh` verifies the
ready and ping frames without a JVM client. `CARP_COMPILER`, `CARP_CORE_DIR`,
and `METACARP_CBOR_HOST` override the discovered paths/output.

`carp-session` itself does not depend on CBOR. A source release will pin
`carp-cbor` as a fetched source dependency; no precompiled server blob is
required.
