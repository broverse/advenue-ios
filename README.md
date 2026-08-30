# Advenue Swift SDK

Native iOS SDK. Spec: `docs/superpowers/specs/2026-08-31-native-ios-sdk-design.md`.

## Targets

- **`AdvenueCore`** — the attribution engine: event envelope, durable queue,
  session state machine, input limits, retry schedule, and the actor that owns
  them. Imports **only Foundation**: no UIKit, no CryptoKit, no URLSession.
  Every platform capability arrives through a protocol.

  That constraint is load-bearing. It is what lets the conformance vectors run
  on a Linux CI runner instead of a macOS one, so a stray platform import is a
  build failure rather than a quiet cost increase.

- `AdvenuePlatform`, `Advenue`, `AdvenueFirebase` — plan 2b.

## Concurrency

The public ingress is `CommandPipe.submit`, which is synchronous, non-blocking
and **ordered**: it yields to an `AsyncStream` drained by a single consumer
task that owns all mutable state. A `Task` per call would not preserve
submission order, and an event could overtake its own `session_start`.

The consumer loop handles every command inside its own `do`/`catch`. An
unhandled throw would end the task, after which `submit` keeps buffering,
nothing sends, nothing errors and the app does not crash — attribution simply
stops. `ConcurrencyTests` pins both properties.

## Conformance

`AdvenueCore` is verified against `packages/conformance/vectors/`, the same
files the TypeScript SDK runs. The Swift package reads a mirror under
`Tests/AdvenueCoreTests/vectors/`, written by `pnpm conformance:sync`; CI
asserts the mirror never drifts.

A Swift result that disagrees with a vector means the port is wrong, not the
vector — vectors are authored from the schemas and vendor documents, never
generated from an implementation.

## Running the tests

```bash
pnpm conformance:sync
cd packages/sdk-swift && swift test
```
