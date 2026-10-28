# `yield_op`: typed suspension points

Rough proposal, October 2026. Nothing here is implemented, and all syntax
is a placeholder.

This note builds on the coroutine design in
[Coroutines: stackless, value-typed, scheduled by libraries](https://aardappel.github.io/goose/docs/design/coroutines.html),
called "the coroutines note" below. It keeps that design's frames,
lowering and rules at a suspension point (R1 to R8), and changes one
thing: the protocol between a coroutine and whoever resumes it. In the
coroutines note, a coroutine declares one yield type and one resume type.
Here, each kind of suspension declares its own request and reply types, as
a function declares its own parameter and return types.

The problem in section 1 was raised on the Goose Discord, in a discussion
of the coroutines note's server example. This note is an attempt at the
fix it asked for.

## 1. The problem

In the coroutines note, every `yield` in a coroutine hands the resumer a
value of the coroutine's yield type, and gets back a value of its resume
type:

```goose
coro fn serve(c: Conn&) yield Wait resume Event { … }
```

Consider a coroutine that runs through fixed stages rather than a loop:
receive a request, check authorization, run a query, reply. Each stage
waits for something different:

```goose
let ev1 = yield Wait.ForRequest;   // expects Event.Request
let ev2 = yield Wait.ForAuth;      // expects Event.AuthResult
let ev3 = yield Wait.ForCrud;      // expects Event.CrudResult
```

The pairing of `ForAuth` with `AuthResult` exists only in the
programmer's head. The type of `ev2` is "some `Event`", and nothing stops a
resumer from answering `ForAuth` with a `CrudResult`. So either:

1. every resumer has to know the coroutine's internals well enough to
   reply correctly, which is unchecked and hard to keep right in a large
   program, or
2. every `yield` site has to be defensive, matching on the reply and
   handling the variants that make no sense there. A wrong reply also
   hands the coroutine data meant for a different stage.

A second rule makes this worse. A coroutine called from another must have
the same yield type as its caller (coroutines note, §4.4). A helper
`await_auth()` that only ever waits for authorization still has to be
typed with the whole `Wait` enum, and it can't be reused by a coroutine
whose `Wait` is a different type.

The problem is not specific to servers. Give the patrol example from the
`suspend_fn` sketch typed yields, and one small coroutine already has two
kinds of pause that want different replies:

```goose
let path = yield FindPath { from: g.pos, to: target };   // wants a Path back
for step in path.steps { g.pos = step; yield NextFrame; } // wants nothing back
```

Suspension points in one coroutine are usually heterogeneous: they wait
for different things and expect different replies.

## 2. The proposal

A `yield` is a call out to whoever resumes the coroutine, and the resume
value is that call's return value. Every call has its own return type, so
every kind of yield should have its own reply type.

### 2.1 Declaring operations

```goose
yield_op next_frame();
yield_op wait_until(t: f64);
yield_op find_path(from: int2, to: int2) -> Path;
```

A `yield_op` is a signature with no body. It names a kind of suspension,
the request it carries (its parameters) and the reply it expects (its
result). An operation with no result is resumed with no value.

Nothing runs when an operation is "called". The coroutine stops, and the
request becomes a value that its resumer receives. The implementation of
the operation is whatever the resumer does with that value (2.4).

Operations are declared like functions: at module level, in namespaces,
reached by qualified names (`io::readable`). Any coroutine may call any
operation it can name.

### 2.2 Calling an operation

Inside a `coro fn`, an operation is called like a function, and its value
is the reply:

```goose
coro fn walk_to(g: Guard&, target: int2) {
    let path = find_path(g.pos, target);    // suspends; resumes with a Path
    for step in path.steps {
        g.pos = step;
        next_frame();
    }
}
```

Each call of an operation is a suspension point, with the coroutines
note's R1 to R8 applying unchanged. An operation may be called only where
the coroutines note allows a `yield`: in a coroutine body, or in a block
inlined into one (§4.6). The `yield` keyword and the `yield Y` and
`resume X` header clauses are no longer needed.

### 2.3 A coroutine's operation set

For every frame type `F`, the compiler computes `F.ops`: the set of
operations `F` can suspend on. It is the operations `F`'s body calls,
plus the operation sets of the coroutines it calls, plus any operations
called in blocks inlined into it.

```goose
coro fn rest(n: f64)          { wait_until(game_time + n); }     // { wait_until }
coro fn walk_to(g, target)    { find_path(…); … next_frame(); }   // { find_path, next_frame }
coro fn patrol(g)             { walk_to(…); rest(…); … }          // { find_path, next_frame, wait_until }
```

Goose compiles the whole program, and coroutines can't be recursive, so
this is one bottom-up pass over the call graph.

`F.ops` is also a type: a tagged union with one variant per operation,
whose payload is that operation's request. It is what `resume` returns.
Since every request is fixed-size (3.1), so is the union.

The "same yield type as the caller" rule of §4.4 goes away. A helper that
uses one operation adds just that one to each caller's set, and library
operations (`io::readable`) mix freely with an application's own
(`check_auth`).

### 2.4 Resuming

```goose
resume(f) -> F.ops, bool                 // start a frame: run to its first suspension
resume(f, op) -> F.ops, bool             // continue after `op`, which has no reply
resume(f, op, reply) -> F.ops, bool      // continue after `op` with its reply
```

Each returns the operation the frame is now suspended in and `true`, or
the zero value of `F.ops` and `false` once the body has returned. This is
the coroutines note's `resume` with the operation named.

Two checks connect the resumer to the coroutine:

* **The match is exhaustive.** A resumer handles a frame's request with a
  `match` on `F.ops`, and the existing exhaustiveness rule (§8.1) applies.
  If someone adds a `play_sound()` call deep inside `walk_to`, every
  resumer of `patrol` stops compiling until it handles `play_sound`, just
  as adding an enum variant breaks every match on that enum.
* **The reply has the operation's type.** `resume(f, find_path, r)`
  type-checks `r` against `find_path`'s result type, `Path`. Naming the
  operation is what makes this a static check even when the reply comes
  much later, in code far from the `match`. At runtime, `resume` checks
  that the frame really is suspended in that operation, and aborts if not
  (3.3). When the compiler can see that it is (`resume` directly in the
  `match` arm for that operation, with no intervening resume of the same
  frame), the check is elided.

### 2.5 Generic resumers

A library event loop does not have to name every coroutine it runs. It is
written generically, and each specialization is checked against the
frame type it is given (§7.7):

```goose
fn run<T>(tasks: T[>..]) {
    … match resume(tasks[i], …) {
        io::readable r => …,
        io::writable w => …,
    } …
}
```

`run(serve_tasks)` compiles only if `serve.ops` is a subset of
`{ io::readable, io::writable }`. If `serve` also calls `check_auth`, the
error is reported at this instantiation and names the operation that is
not handled.

## 3. Rules

### 3.1 Declarations

* An operation's parameters and result are fixed-size. A request travels
  to the resumer and a reply into the frame; neither has a destination
  that could hold a nonfixed value across the suspension, which is the
  reason the coroutines note gives for fixed yield and resume types
  (§4.1, §6.8).
* A request may hold references, slices and links, as a return value
  may. They are checked as the coroutines note checks a yield value: none
  may be rooted at the coroutine's own locals (R4). A request that hands
  the kernel a slice of a pooled buffer is the intended use (§5 of the
  coroutines note).
* A reply is checked as a store into the frame: it may hold only
  references whose roots the frame may hold (§4.8).
* Operations have no bodies, no defaults and no overloads in v1. They may
  not be `extern`, `export`, `thread_fn` or `recursive`.

### 3.2 Declared operation sets

`F.ops` is inferred. A coroutine may also declare it:

```goose
coro fn serve(c: Conn&<u32 in conns>) uses io::readable, io::writable, check_auth { … }
```

When a `uses` clause is present, a call in the body or the call tree of
an operation outside the list is an error at that call, instead of at
some resumer. The list is also documentation: a reader of `serve` sees
what it can wait on.

This follows how Goose treats result types, which are inferred but may be
written (§7.1). Zig's first async design inferred whether a function was
async and was removed, partly because that property was viral and
invisible. The risk here is smaller, since a coroutine is always marked
`coro fn` and only its set is inferred, but library coroutines and
long-lived APIs should write `uses`.

### 3.3 Lowering

Nothing changes in the frame. The coroutines note's tag already records
where the body is suspended, so the operation set adds no bytes to it.
The request union is returned like a yield value, in registers or
through an out-pointer.

The compiler numbers a frame's suspension points so that all calls of one
operation get consecutive tags. "Is this frame suspended in `find_path`"
is then a range check on the tag, one compare and branch, like a bounds
check (§9.3). The coroutines note's own "resumed a finished coroutine"
check already reads the tag, so the two can share the load.

A program with no `yield_op` compiles as it does today.

## 4. The patrol

The patrol example from the `suspend_fn` sketch, with operations:

```goose
struct Guard { pos: int2, post: int2, home: int2 }
struct Path  { steps: int2[..64] }

yield_op next_frame();                                   // resume me next frame
yield_op wait_until(t: f64);                             // resume me once game_time >= t
yield_op find_path(from: int2, to: int2) -> Path;        // resume me with a route

var game_time = 0.0;

coro fn patrol(g: Guard&) {
    loop {
        walk_to(g, g.post);
        rest(2.0);
        walk_to(g, g.home);
        rest(2.0);
    }
}

coro fn walk_to(g: Guard&, target: int2) {
    let path = find_path(g.pos, target);
    for step in path.steps {
        g.pos = step;
        next_frame();
    }
}

coro fn rest(seconds: f64) {
    wait_until(game_time + seconds);
}

struct PathJob   { task: i64, from: int2, to: int2 }
struct PathReply { task: i64, path: Path }

thread_fn pathfinder() {
    loop { let j = qget<PathJob>(); qput(PathReply { task: j.task, path: astar(j.from, j.to) }); }
}

enum Wake { NextFrame, At { t: f64 }, Path }             // why each patrol is parked

fn schedule(i: i64, op: patrol.ops) -> Wake {
    match op {
        next_frame   => Wake.NextFrame,
        wait_until w => Wake.At { t: w.t },
        find_path f  => { qput(PathJob { task: i, from: f.from, to: f.to }); Wake.Path },
    }
}

fn main() {
    thread_spawn(pathfinder);
    var guards: Guard[>..] = load_guards();
    var patrols: patrol[>..] = [];
    var wake: Wake[>..] = [];
    for i in guards.len {
        patrols.push(patrol { guards[i] });
        let op, live = resume(patrols[i]);
        wake.push(schedule(i, op));
    }
    while !quit_requested() {
        for i in patrols.len {                           // patrol never finishes, so live stays true
            match wake[i] {
                NextFrame => { let op, live = resume(patrols[i], next_frame); wake[i] = schedule(i, op); },
                At a      => if game_time >= a.t {
                                 let op, live = resume(patrols[i], wait_until); wake[i] = schedule(i, op);
                             },
                Path      => {},
            }
        }
        loop {
            let r, ok = qpoll<PathReply>();
            guard ok else { break; }
            let op, live = resume(patrols[r.task], find_path, r.path);
            wake[r.task] = schedule(r.task, op);
        }
        game_time += STEP;
        draw(guards);
    }
}
```

Compared with the `suspend_fn` version:

* `Guard` loses its `has_path` and `path` fields, and `main` no longer
  copies routes into guards. Those fields and that copying loop were a
  reply channel written by hand. Now the route is the reply to
  `find_path`, so `let path = find_path(…)` reads like the blocking call
  the example wanted to write in the first place.
* A resting guard, or one waiting for a route, is not resumed until there
  is something for it to do. The `suspend_fn` version resumed every guard
  every frame to test a predicate.
* `main` has a small scheduler instead (`Wake` and `schedule`). That
  comes from yields carrying requests, which the coroutines note already
  has, not from operations specifically. Only `find_path` is specific to
  this game: `next_frame` and `wait_until` could be handled by a library
  frame scheduler (6).
* `path` is now a local that crosses suspensions, so it is part of the
  frame: about 520 bytes per guard, copied in and out on each resume
  under the coroutines note's lowering (its open question on large
  hoisted locals). Writing `g.path = find_path(…)` and iterating
  `g.path.steps` keeps the route in the guard and the frame small.

The scheduler is optional. A version that polls, with `next_frame` as its
only operation and `rest` written as `while game_time < until {
next_frame(); }`, needs only `for &p in patrols { resume(p, next_frame); }`
in `main`. Each kind of wait a program routes through its resumer instead
of polling costs one arm in the resumer's `match`, and the program
chooses per operation.

## 5. The server

The coroutines note's server (its section 5), with an authorization stage
added to give it heterogeneous suspension points:

```goose
// In io, written once and shared by every server
enum Ready { Ok, Hangup, Cancel }
yield_op readable(fd: i64) -> Ready;
yield_op writable(fd: i64) -> Ready;

// The application
struct Conn { fd: i64, inbuf: u8[..4096], outbuf: u8[..4096] }
reusable var conns: Conn[>..] = [];

struct Token { bytes: u8[..64] }
enum AuthResult { Ok { user: i64 }, Denied }

yield_op check_auth(t: Token) -> AuthResult;

coro fn fill(c: Conn&<u32 in conns>) -> bool {
    loop {
        let n = net::recv(c.fd, c.inbuf);
        if n != net::AGAIN { return n > 0; }
        guard io::readable(c.fd) == io::Ready.Ok else { return false; }
    }
}

coro fn flush(c: Conn&<u32 in conns>) -> bool { … }   // the same, with io::writable

coro fn serve(c: Conn&<u32 in conns>) {
    loop {
        guard fill(c) else { return; }
        let token = http::auth_token(c.inbuf[..]);
        let who = check_auth(token);
        let consumed = http::respond(c.inbuf[..], who, c.outbuf);
        guard consumed > 0 else { continue; }
        drop_front(c.inbuf, consumed);
        guard flush(c) else { return; }
    }
}

struct AuthJob   { task: i64, token: Token }
struct AuthReply { task: i64, result: AuthResult }

reusable var tasks: serve[>..] = [];
var by_fd: i64[>..] = [];

fn dispatch(i: i64, op: serve.ops, suspended: bool) {
    guard suspended else {
        let fd = tasks[i].c.fd;
        conns.free(conns.index_of(tasks[i].c)); tasks.free(i); net::close(fd);
        return;
    }
    match op {
        io::readable r => net::watch(r.fd, net::READ, i),
        io::writable w => net::watch(w.fd, net::WRITE, i),
        check_auth a   => qput(AuthJob { task: i, token: a.t }),
    }
}

fn run(listen_fd: i64) {
    loop {
        for ev in net::poll_wait(…) {
            let i = by_fd[ev.fd];
            let r = if ev.hangup { io::Ready.Hangup } else { io::Ready.Ok };
            let op, s = if ev.readable { resume(tasks[i], io::readable, r) }
                        else           { resume(tasks[i], io::writable, r) };
            dispatch(i, op, s);
        }
        loop {
            let a, ok = qpoll<AuthReply>();
            guard ok else { break; }
            let op, s = resume(tasks[a.task], check_auth, a.result);
            dispatch(a.task, op, s);
        }
        … accept new connections: start a frame with resume(tasks[i]) and dispatch it …
    }
}
```

Compared with the coroutines note's version:

* No coroutine header has a `resume Event` clause. The coroutines note
  calls that clause "the least settled part" of its syntax.
* `io::readable` is answered with a `Ready` and `check_auth` with an
  `AuthResult`, and the compiler checks both. Neither has to handle the
  other's replies.
* `fill` and `flush` use only io's operations, `serve` adds its own, and
  no shared `Wait` type had to anticipate both.
* `dispatch`'s `match` must cover `serve.ops`. In the coroutines note,
  the loop's `match w` covers the `Wait` enum, but nothing connects that
  enum to what `serve` actually yields.

Two problems are carried over unchanged from the original example. A task
index such as `a.task` can go stale when its slot is freed and reused,
which a generation counter would fix. With several server workers, the
per-type queues of §11.2 could deliver an `AuthReply` to the wrong
worker.

## 6. The resumer supplies the implementation

Since an operation has no body, different resumers can implement the same
operation differently, and the coroutine does not change:

* the game sends `find_path` to a worker thread,
* a test answers it at once with a fixed route, so `patrol` can be tested
  deterministically, with no threads and no pathfinder,
* a replay tool answers it with routes recorded from an earlier run.

This is the sans-I/O style the coroutines note recommends for protocol
code (§4.13), applied to coroutines themselves: the coroutine says what
it needs, and its environment decides how to provide it.

It also raises the question of how resumers compose. A game would like a
library scheduler for `next_frame` and `wait_until` and to add arms only
for its own operations. One shape is a generic library loop that takes a
block for the operations it does not know:

```goose
frames::run(patrols) { i, op =>
    match op {
        find_path f => …,
    }
}
```

Exhaustiveness then has to be checked across the library's arms and the
block's together. Whether that falls out of specialization or needs a new
rule is open (8).

## 7. Cancellation

In the coroutines note, `Event.Cancel` can be the reply to any yield.
With per-operation replies, an operation whose reply type has no cancel
variant (`check_auth`) gives the resumer no way to say "stop". There are
three ways to stop a coroutine:

| Kind | Mechanism | Coroutine can clean up? |
|---|---|---|
| Hard | the resumer drops the frame and frees its pool entries | no |
| Forced unwind | a builtin `cancel(f)` resumes the frame, and the pending operation acts as a `return … from` the outermost coroutine | only if something can catch it |
| Cooperative | a `Cancel` variant in the reply type, then `return … from` to get out | yes |

The hard kind already works and costs nothing, because a frame owns no
stack and Goose has no destructors (coroutines note, §4.10). It is enough
whenever the coroutine has nothing of its own to undo.

The forced unwind reuses §7.9's mechanism. The hidden return discriminant
is set to "propagate" at the pending operation, and each coroutine frame
in between returns at once. This gives every operation a cancel path
without putting `Cancel` into every reply type. But there is no `defer`
across a suspension (R5) and no destructor, so no cleanup code runs on the
way out, and by itself the forced unwind is equivalent to dropping the
frame. It becomes useful only together with a construct that can catch
it, such as the coroutine-friendly `try` with a fixed-size error slot that
the coroutines note suggests (§4.7). Then the coroutine can send its
client an error or release what it holds.

The cooperative kind needs no language support, and `return … from` makes
it cheap to write: a helper deep in the call tree that sees
`Ready.Cancel` returns straight from `serve` instead of through a chain of
`guard … else { return false; }`.

## 8. Open questions

* Inferred operation sets with an optional `uses` clause (3.2), or a
  required declaration.
* Cancellation (7): whether the forced unwind and a catching construct
  belong in v1, or whether hard and cooperative cancellation are enough.
* Generic operations. A generator wants `yield_op emit<T>(v: T)`, which
  needs operation sets to carry type arguments. Without it, each generator
  declares its own `emit`.
* The name and syntax of `F.ops`, and whether a `match` on it should name
  operations bare (`find_path f =>`) or as `F.ops.find_path`.
* Composing resumers (6): how a library scheduler and an application
  divide one frame's operations, with exhaustiveness checked across both.
* Whether a bare `yield;` should stay as sugar for a predeclared
  `next`-style operation, so that the simplest game coroutine does not
  need a declaration.
* Whether the runtime tag check of 2.4 should exist in release builds.
  Without it, a wrong reply is a logic error rather than a type error, as
  re-entry is in the coroutines note (§4.10). It costs one compare, so
  keeping it seems right.

## 9. Prior art

* **Kotlin.** A leaf suspend function such as `suspend fun read():
  ByteArray` resumes with a `ByteArray`, and the continuation at that
  point is a `Continuation<ByteArray>`. The reply type belongs to the
  suspension point, which is what this note proposes. Kotlin pays for it
  with a heap-allocated continuation and a virtual `resumeWith`; here the
  pairing is checked at compile time and the frame stays a value.
* **Algebraic effects** (Koka, OCaml 5, Eff). An effect operation is
  declared with its argument and result types, and a handler supplies its
  implementation. A `yield_op` is an effect operation restricted to
  one-shot, stackless handling, with the handler living in the resumer
  rather than on the call stack.
* **Python generators and Rust's unstable coroutines** have a single
  send or resume type per coroutine, like the coroutines note, and the
  same mismatch between that type and what each suspension point expects.
* **Sans-I/O** (Python's protocol libraries): protocol code that consumes
  and produces data and never does I/O itself. Section 6 is that style for
  coroutines.
