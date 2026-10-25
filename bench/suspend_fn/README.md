# `suspend_fn` prototype: the patrol benchmark

This benchmark measures the guard patrol from
[`docs/design/suspend_fn.md`](../../docs/design/suspend_fn.md). The compiler
has no `suspend_fn`, so [`patrol.goose`](patrol.goose) contains the code a
`suspend_fn patrol` would lower to, written by hand in today's Goose. Each
version prints a checksum of the final guard positions, and the checksums
agree, so all versions do the same work.

A guard walks 20 frames to its post, rests 30 frames, walks back and rests
again, forever. The versions are:

* **state machine**: today's idiom. A `GuardState` enum and a `tick`
  function, as in the proposal's "before" example.
* **coroutine**: one resume function per suspend function (`patrol`,
  `walk_to`, `rest`), each a program counter plus the locals live across
  a suspension. The callee's state is nested inside the caller's. This is
  the simplest lowering.
* **flat coroutine**: the same patrol, with `walk_to` and `rest` inlined
  into `patrol`, so there is one program counter and one state per
  suspension point. A lowering that inlines suspend calls would emit this.
* **thread**: the patrol as straight-line code in a `thread_fn`. Waiting
  for the next frame is a `qput` of the guard's position and a blocking
  `qget<Tick>()`. This is the only way to write a blocking patrol today.

```
goose build patrol.goose && ./patrol [guards] [frames] [thread_frames]
```

## Results

Apple M3 Pro, Apple clang 21, `goose build` at `-O2`, best of 5 runs.
Three separate runs agreed within 3%.

10,000 guards for 10,000 frames:

| version | time | per guard per frame | state per guard |
|---|---:|---:|---:|
| state machine | 88 ms | 0.88 ns | 22 bytes |
| coroutine (nested) | 128 ms | 1.28 ns | 48 bytes |
| flat coroutine | 97 ms | 0.97 ns | 24 bytes |

One guard for 100,037 frames:

| version | time | per frame |
|---|---:|---:|
| coroutine | 0.18 ms | 1.8 ns |
| thread | 345 ms | 3,450 ns |

## What this shows

* **Switching:** a resume costs about a nanosecond. A thread round trip
  through the typed queues costs about 3.5 microseconds, which is roughly
  1,900 times as much. Each direction of the round trip takes a mutex,
  allocates a message node and wakes the other thread (this was not
  profiled further).
* **Scale:** 10,000 thread-based guards are impossible here. macOS allows
  4,096 threads per process (`kern.num_taskthreads`); `thread_spawn` worked
  for 4,000 idle workers and aborted with `cannot create thread` at 5,000.
  A coroutine needs 24 to 48 bytes, so 10,000 of them take under
  half a megabyte. Threads also can't read the game's globals or move a
  guard that main draws, so for this job they are a stand-in at best.
* **The lowering matters:** the nested lowering is 45% slower than the
  hand-written state machine. In the generated C, every frame tests the
  outer program counter and then the inner one, and each transition writes
  a fresh callee state. When the nested calls are merged into one program
  counter, the gap drops to about 10%. The remaining difference is that
  the flat version does a little more bookkeeping at each transition than
  the hand-written enum does.

In short: code written as a coroutine costs about the same as the state
machine it replaces, provided the compiler flattens nested suspend calls.
Threads are three orders of magnitude slower for this kind of work.

## Caveats

* The coroutines are lowered by hand, so the numbers show what a compiler
  could produce, not what one does. A real lowering may do better
  (keeping hot locals in registers between suspensions) or worse.
* The thread comparison is one guard and one worker, so that each tick
  goes to the right worker. With more workers on the same typed queue,
  any worker could take any tick.
* Each guard's patrol does very little work per frame, which magnifies
  the switching cost. In a real game the per-frame logic would dominate.
