# Proposal: `suspend_fn`, coroutines without a heap

Rough sketch, October 2026. Nothing here is implemented. The syntax is
a placeholder. This note asks whether Kotlin-style suspend functions fit
Goose, and suggests a shape for them that follows rules the language
already has.

## 1. Before and after

A game has guards that patrol between two points. A guard asks a
pathfinding worker for a route, walks it one step per frame, rests for two
seconds, and then walks back. The game must keep drawing frames while a
guard waits, so no guard may block.

The code below is shared by both versions:

```goose
import std;
import vec;

struct PathJob { guard: i32, from: int2, to: int2 }
struct Path    { guard: i32, steps: int2[..64] }     // fixed size: a limited array

thread_fn pathfinder() {
    loop { qput(find_path(qget<PathJob>())); }
}

var game_time = 0.0;
```

### Before: a hand-written state machine

What we want to write is `walk_to(post); rest(2.0); walk_to(home); …`, but
`qget<Path>()` would stop every guard and the renderer while it waits. So
the patrol is turned inside out. Its position in the patrol becomes an
enum, and a `tick` function is called once per frame to move it on by one
step:

```goose
enum GuardState { Idle, WaitingForPath, Walking { step: i64 }, Resting { until: f64 } }

struct Guard {
    pos: int2, post: int2, home: int2,
    path: Path, has_path: bool,
    state: GuardState, going_home: bool,
}

fn tick(g: Guard&, i: i32) {
    match g.state {
        Idle => {
            let target = if g.going_home { g.home } else { g.post };
            g.has_path = false;
            qput(PathJob { guard: i, from: g.pos, to: target });
            g.state = GuardState.WaitingForPath;
        },
        WaitingForPath => {
            if g.has_path { g.state = GuardState.Walking { step: 0 }; }
        },
        Walking w => {
            if w.step < g.path.steps.len {
                g.pos = g.path.steps[w.step];
                g.state = GuardState.Walking { step: w.step + 1 };
            } else {
                g.state = GuardState.Resting { until: game_time + 2.0 };
            }
        },
        Resting r => {
            if game_time >= r.until {
                g.going_home = !g.going_home;
                g.state = GuardState.Idle;
            }
        },
    }
}
```

The patrol's actual logic (go there, rest, come back) is spread over four
match arms, plus a `going_home` flag that says which half of the loop we
are in. `samples/31_mini_doom.goose` does the same thing with the `timer`,
`pain`, `death` and `attacking` fields of `Actor`.

### After: `suspend_fn`

```goose
struct Guard { pos: int2, post: int2, home: int2, path: Path, has_path: bool }

suspend_fn patrol(g: Guard&, i: i32) {
    loop {
        walk_to(g, i, g.post);
        rest(2.0);
        walk_to(g, i, g.home);
        rest(2.0);
    }
}

suspend_fn walk_to(g: Guard&, i: i32, target: int2) {
    g.has_path = false;
    qput(PathJob { guard: i, from: g.pos, to: target });
    wait_until() { g.has_path };
    for step in g.path.steps {
        g.pos = step;
        suspend();                                  // one step per frame
    }
}

suspend_fn rest(seconds: f64) {
    let until = game_time + seconds;
    wait_until() { game_time >= until };
}

suspend_fn wait_until<F>() {
    while !F() { suspend(); }
}
```

The `state` enum and the `going_home` flag are gone, because the position
in the patrol is now where the code is. The frame loop starts one
coroutine per guard and resumes each of them once per frame:

```goose
fn main() {
    thread_spawn(pathfinder);
    var guards: Guard[>..] = load_guards();
    var patrols: co<patrol>[>..] = [];
    for i in guards.len { patrols.push(co_start(patrol, guards[i], i as i32)); }
    while !quit_requested() {
        loop {                                       // route arriving paths to their guards
            let p, ok = qpoll<Path>();
            guard ok else { break; }
            guards[p.guard].path = p;
            guards[p.guard].has_path = true;
        }
        for &p in patrols { co_resume(p); }
        game_time += STEP;
        draw(guards);
    }
}
```

## 2. Do coroutines fit Goose?

They fit, for reasons that are specific to Goose.

* **Threads cannot do this job.** A `thread_fn` is a separate program
  with its own copies of the globals. A guard written as a thread could
  not read `game_time` or move a guard that main draws. Coroutines run on
  the thread that resumes them and share its memory, and since they only
  switch at `suspend()`, sharing causes no data races.
* **Blocks don't cover it either.** A block with `return` gives internal
  iteration (`each_split`, `filter`). It can't express logic that stops
  partway and continues on a later frame, or a generator that a consumer
  pulls one value at a time from.
* **The rule that makes it cheap already exists.** §7.8 says a recursive
  function may not call back into its cycle while a nonfixed local is in
  scope. The same rule applied to `suspend()` means a suspended coroutine
  holds no data stack, so its whole state is a small fixed-size value
  (section 3).
* **Structured concurrency comes for free.** In Kotlin, structured
  concurrency is a library discipline. In Goose, a coroutine is a value
  owned by a scope, and the outlives rule (§9.1) already stops it from
  outliving anything it refers to. When its owner's scope ends it is
  freed, and since Goose has no destructors, nothing has to run.
* **No `Pin` is needed.** Rust needs `Pin` because a future can be moved
  after it has started pointing into itself. A Goose value is built in
  place (§4.3) and nothing moves. If coroutine values are never copied,
  the problem cannot happen.

The costs are real too. Functions get a colour, as in Kotlin and Rust:
only a `suspend_fn` can call `suspend()` or another `suspend_fn`. The code
generator needs a new lowering, and the restrictions in section 4 will
sometimes bite. Today the language has no networking or asynchronous I/O,
so the main uses are game and UI logic that runs across frames, waiting
for workers, and generators.

## 3. How it compiles

The idea in the original sketch is the right one: the compiler turns the
function into a state value and a step function that `match`es on it. The
refinement is what the variants hold. There is one variant per suspension
point, and its payload is the locals that are live there. `rest` lowers to
roughly this:

```goose
enum rest_state {
    Start   { seconds: f64 },
    Waiting { until: f64 },       // the one suspension point, with the local live there
    Done,
}

fn rest_resume(s: rest_state&) -> bool {             // true once finished
    loop {
        match s {
            Start st  => { s = rest_state.Waiting { until: game_time + st.seconds }; },
            Waiting w => {
                if game_time < w.until { return false; }   // suspend
                s = rest_state.Done;
            },
            Done => return true,
        }
    }
}
```

`wait_until` disappears into `rest`, because function values are always
inlined.

A call from one suspend function to another stores the callee's state
inside the caller's variant. For example, `patrol`'s variant for "in the
first `walk_to`" has a `walk_to_state` in its payload, which in turn holds
the step index. A coroutine's state is therefore a tree of enums with a
size that is known at compile time. This works because the program is
compiled whole and suspend functions cannot be recursive. Rust's `async fn`
uses the same layout. Kotlin allocates a continuation object on the heap
for each suspending call instead, which Goose cannot do.

Since Goose compiles to C, the backend does not have to build these enums
literally. It can emit one C function with a `switch` that jumps to the
label after the last suspension, and keep the live locals in a struct that
is a union of each point's live set. Either way, resuming a coroutine is a
direct call. Its type names its function, so there is no function pointer.

## 4. Rules

1. `suspend()` and calls to `suspend_fn`s are allowed only inside a
   `suspend_fn`, and within it only in its own body and in blocks
   inlined into it.
2. Suspend functions cannot be recursive, because that would make the
   state's size unbounded.
3. **At a suspension point, no nonfixed local or temporary may be live.**
   This is §7.8's rule, with `suspend()` in the role of the recursive
   call. Fixed values, including limited arrays like `int2[..64]` and
   references, can be held across a suspension. Growable data that a
   coroutine needs is owned outside it and passed in by reference, as it
   is for recursion. Between two suspensions, a coroutine can use scratch
   buffers like any function does. They live on the resumer's stacks and
   are freed before the coroutine suspends.
4. A coroutine value, `co<f>`, is fixed-size, is built in place, and is
   never copied. It counts as holding the references it was started with,
   so the outlives rule applies to it as it would to a struct of those
   references.
5. A coroutine is not flat, so it can't cross to another thread.

Rule 3 is the main limitation. One way to lift it later is to give a
coroutine its own block of data stacks, as a thread program has
(`gs_stack_block`, §11.3's "dynamic stacks"). Resuming it would then
switch `gs_stks`. That costs address space per coroutine, so it would be
something a coroutine opts into, not the default.

## 5. The bridge, `async` and `await`

Only a few builtins are needed. Ordinary code uses them to start and drive
coroutines:

| Builtin | Meaning |
|---|---|
| `co_start(f, args…) -> co<f>` | creates a coroutine for `suspend_fn f`; nothing runs yet |
| `co_resume(c) -> bool` | runs `c` to its next suspension; `true` once it has finished (and on every call after that) |
| `co_result(c)` | the finished coroutine's results |
| `suspend()` | inside a `suspend_fn`: hands control back to the caller of `co_resume` |

`co_start` follows `thread_spawn(worker, args…)`. Kotlin's `runBlocking`
can then be an ordinary function:

```goose
fn run_blocking(c) {
    while !co_resume(c) {}
    return co_result(c);
}
```

Kotlin's `async` and `await` can be ordinary functions too. A Kotlin
`Deferred` is a coroutine that has been started, so `async` is `co_start`,
and `await` is a suspend function that drives its argument until it is
done:

```goose
suspend_fn await(c) {                     // generic: any co<…>
    while !co_resume(c) { suspend(); }
    return co_result(c);
}

suspend_fn await_all(a, b) {              // drives both, so they overlap
    loop {
        let a_done = co_resume(a);
        let b_done = co_resume(b);
        if a_done && b_done { return; }
        suspend();
    }
}

suspend_fn fetch_both() -> i64 {
    var a = co_start(path_length, 1);
    var b = co_start(path_length, 2);
    await_all(a, b);
    return co_result(a) + co_result(b);
}
```

There is one difference from Kotlin. A Kotlin dispatcher runs every
started coroutine, while a Goose coroutine runs only when something
resumes it. `await(a); await(b);` therefore runs `a` to completion before
`b` starts, and `await_all` is how two coroutines are made to overlap. A
scheduler could be written as a library on top of this. A collection of
coroutines of different kinds would be an enum of `co<…>` types with case
functions, which is how Goose already does dynamic dispatch.

`var a = async() { path_length(1) };` would read most like Kotlin. That
means letting a coroutine store a block. This is less of a departure than
it looks. The block's code is known at compile time and is part of the
type, so only its state is stored, and the outlives rule already stops
the coroutine from outliving the locals the block uses.

## 6. Performance: what to expect

This has not been measured. A `co_resume` is a direct call and a `switch`,
plus a few loads and stores of state, so it should cost a few nanoseconds.
Sending a message to a worker and receiving its reply goes through
`gs_qput`, which takes a mutex, allocates a node, and wakes a condition
variable. Each direction typically takes microseconds when the receiver
has to be woken. A worker also reserves its own data stacks and an OS
thread. A `patrol` coroutine is a few hundred bytes, mostly its `Path`.

A useful benchmark would compare two ping-pong loops that each pass a
counter back and forth a million times. One would use a `thread_fn` with
`qput`/`qget`, and the other would use a state machine written by hand in
the shape of section 3, which is what a `suspend_fn` would compile to. The
same pair, run with 10,000 concurrent "actors", would also show memory use.
The two are not interchangeable: threads run in parallel and coroutines
don't. The benchmark would show what it costs to use a thread for work
that only needs to wait.

## 7. Open questions

* Names: `suspend_fn` matches `thread_fn`, while `co_start`/`co_resume`
  and `co<f>` are placeholders.
* Should `return … from` be allowed to cross a suspension, inside one
  coroutine? It should not cross `co_resume`.
* Can a block passed to an ordinary HOF suspend, so that a `suspend()`
  inside `for_each(xs) { … }` works? Kotlin allows this for inline lambdas.
  In Goose every block is inlined, but the HOF's own locals would then
  have to become part of the coroutine's state.
* Is a "fixed but not copyable" kind of value new to the type system, or
  can it reuse how non-fixed values already refuse implicit copies?
* Generators (`yield(v)` as `suspend()` with a value written to the
  coroutine's output slot) fall out of the same machinery. Should they be
  part of the first version?
