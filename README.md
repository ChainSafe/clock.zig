# zig-beacon-clock

Beacon chain slot/epoch clock for Ethereum consensus, implemented in Zig (`0.16.0-dev`, `std.Io`).

Drop-in replacement for Lodestar's TypeScript `Clock` class (`packages/beacon-node/src/util/clock.ts`), with identical catch-up and event semantics.

## Architecture

Three-layer design. Each layer depends only on the one below it.

```
┌─────────────────────────────────────────────────────┐
│  Layer 2 – EventClock            (EventClock.zig)   │
│  Async event loop, listeners, waiters, catch-up     │
├─────────────────────────────────────────────────────┤
│  Layer 1 – SlotClock             (SlotClock.zig)    │
│  Stateful clock, wall-clock reads, AdvanceIterator  │
├─────────────────────────────────────────────────────┤
│  Layer 0 – slot_math             (slot_math.zig)    │
│  Pure arithmetic, no state, no I/O, comptime-safe   │
└─────────────────────────────────────────────────────┘
         TimeSource (time_source.zig) ← injected
```

### Layer 0 — `slot_math.zig`

Pure functions mapping between Unix timestamps, slots, and epochs. No state, no allocation, no I/O. All overflow paths return `null` (`?T`) instead of panicking.

- `slotAtMs`, `slotAtSec` — timestamp → slot
- `epochAtSlot` — slot → epoch
- `slotStartSec`, `slotStartMs` — slot → timestamp
- `msUntilNextSlot` — time until next slot boundary
- `Config` with `validate()` — rejects zero divisors and sec→ms overflow at init time

### Layer 1 — `SlotClock.zig`

Wraps `slot_math` with a `TimeSource` and a cached `current_slot`. Pure-read helpers query wall-clock time; only `advanceTo()` mutates the cache.

- `currentSlot`, `currentEpoch` — wall-clock read (does **not** update cache)
- `currentSlotOrGenesis`, `currentEpochOrGenesis` — returns `0` pre-genesis
- `currentSlotWithGossipDisparity` — bumps to next slot when within `MAXIMUM_GOSSIP_CLOCK_DISPARITY`
- `isCurrentSlotGivenGossipDisparity` — checks both "near next" and "just past current" boundaries
- `slotWithFutureTolerance`, `slotWithPastTolerance` — shifted slot reads
- `secFromSlot`, `msFromSlot` — elapsed time since a slot
- `advanceTo(target) → AdvanceIterator` — steps `current_slot` one-by-one toward `target`, yielding `.slot` and `.epoch` events in order

### Layer 2 — `EventClock.zig`

Async event-driven clock built on `std.Io`. Combines `SlotClock` with a cooperative fiber loop to emit slot/epoch events and dispatch waiters.

**Lifecycle:**

```
init() → onSlot/onEpoch() → start() → ... → stop() → join() → deinit()
```

- `init` — in-place initialization (self-referential struct, not returned by value)
- `start` — spawns `runAutoLoop` fiber via `std.Io.async`. Idempotent
- `stop` — signals loop to exit, aborts all pending waiters. Idempotent
- `join` — awaits loop fiber completion (workaround for Zig bug [#31307](https://codeberg.org/ziglang/zig/issues/31307))
- `deinit` — calls `stop()` + `join()`, frees all resources

**Listener API:**

```zig
const id = try clock.onSlot(callback, ctx);
_ = clock.offSlot(id);
```

- Slot and epoch listeners registered before `start()` are guaranteed delivery
- Snapshot-based emission prevents iterator invalidation during callbacks
- Listener capacity is pre-allocated — no allocation in the emission hot path

**waitForSlot:**

```zig
var fut = try clock.waitForSlot(target_slot);
try fut.await(io);
```

- Returns immediately if already at or past target slot
- Future-based API backed by `std.Io.Event` + `std.Io.Future`
- Dispatched by `advanceAndDispatch` when `current_slot >= target`
- `cancelWait` available for error-path cleanup
- Returns `error.Aborted` on `stop()`

**Catch-up semantics (matching TS `get currentSlot()`):**

Every public accessor that exposes "current" slot/epoch state calls `catchUp()` first — the same pattern as the TS version where `get currentSlot()` triggers event emission before returning. This ensures listeners and waiters see events even if the auto-loop hasn't ticked yet.

Affected accessors: `currentSlot`, `currentEpoch`, `currentSlotOrGenesis`, `currentEpochOrGenesis`, `currentSlotWithGossipDisparity`, `isCurrentSlotGivenGossipDisparity`.

Pure arithmetic helpers (`slotWithFutureTolerance`, `slotWithPastTolerance`, `secFromSlot`, `msFromSlot`) do **not** catch up, matching TS which doesn't go through `this.currentSlot` for those.

**Auto-loop (`runAutoLoop`):**

- Sleeps in 500ms chunks for prompt `stop()` response (cannot cancel sleeping futures due to Zig bug #31307)
- Skips advancement pre-genesis (`currentSlot()` returns `null`)
- Checks `stopped` flag in `advanceAndDispatch` loop (matches TS's `!this.signal.aborted`)
- Falls back to `self.stop()` + `break` if `msUntilNextSlot` returns `null` (config overflow defense-in-depth)

### `time_source.zig`

Pluggable time source abstraction. `TimeSource.fromIo(*std.Io)` bridges to `std.Io.Clock.real` for production; tests inject fake clocks via function pointer for deterministic control.

## Concurrency model

`std.Io.Evented` runs N:1 cooperative fibers on a single OS thread — the same model as JavaScript's single-threaded event loop. No concurrent access, so `catchUp()` / `advanceAndDispatch` are safe to call from any fiber without synchronization.

## TS semantic alignment

This implementation matches the Lodestar `Clock` class behavior:

| TS pattern | Zig equivalent |
|---|---|
| `get currentSlot()` catches up events before returning | `catchUp()` called in all current-state accessors |
| `onNextSlot` loop checks `!this.signal.aborted` | `advanceAndDispatch` checks `self.stopped` per event |
| `waitForSlot` uses `this.currentSlot` getter (triggers catch-up) | `catchUp()` + `current_slot` fast-path |
| `setTimeout(this.onNextSlot, this.msUntilNextSlot())` | `std.Io.sleep` in 500ms chunks + `advanceAndDispatch` |
| `slot 0` not emitted pre-genesis | `currentSlot()` returns `null` pre-genesis, loop skips |

## Public API

From `src/lib.zig`:

```zig
const clock = @import("zig_beacon_clock");

// Types
clock.Slot       // u64
clock.Epoch      // u64
clock.Config     // { genesis_time_sec, seconds_per_slot, slots_per_epoch, maximum_gossip_clock_disparity_ms }
clock.ListenerId // u64
clock.Error      // error{ InvalidConfig, OutOfMemory, ListenerLimitReached, Aborted }

// Layer 0 — pure functions
clock.slot_math.slotAtMs(config, now_ms) -> ?Slot
clock.slot_math.slotAtSec(config, now_sec) -> ?Slot
clock.slot_math.epochAtSlot(config, slot) -> ?Epoch
clock.slot_math.slotStartSec(config, slot) -> ?UnixSec
clock.slot_math.slotStartMs(config, slot) -> ?UnixMs
clock.slot_math.msUntilNextSlot(config, now_ms) -> ?u64

// Layer 2 — event-driven clock (primary API)
var ec: clock.EventClock = undefined;
try ec.init(allocator, config, io);
defer ec.deinit();

ec.start();
ec.stop();
ec.join();

ec.currentSlot() -> ?Slot
ec.currentEpoch() -> ?Epoch
ec.currentSlotOrGenesis() -> Slot
ec.currentEpochOrGenesis() -> Epoch
ec.currentSlotWithGossipDisparity() -> Slot
ec.isCurrentSlotGivenGossipDisparity(slot) -> bool
ec.slotWithFutureTolerance(ms) -> ?Slot
ec.slotWithPastTolerance(ms) -> ?Slot
ec.secFromSlot(slot, ?to_sec) -> ?i64
ec.msFromSlot(slot, ?to_ms) -> ?i64

try ec.onSlot(callback, ctx) -> ListenerId
ec.offSlot(id) -> bool
try ec.onEpoch(callback, ctx) -> ListenerId
ec.offEpoch(id) -> bool

var fut = try ec.waitForSlot(target);
try fut.await(io);
ec.cancelWait(&fut);
```

## Build & test

```bash
zig build test
```

Requires Zig `0.16.0-dev` (master) with `std.Io` support.
