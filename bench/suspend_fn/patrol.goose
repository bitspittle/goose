// The guard patrol of docs/design/suspend_fn.md, written three ways and
// timed. A guard walks STEPS frames to its post, rests REST frames, walks
// back and rests again, forever. Each version advances every guard by one
// frame per frame, and prints a checksum of the final positions, so the
// versions can be checked against each other.
//
//  1. state machine: today's idiom, a GuardState enum and a tick function.
//  2. coroutine: the code a `suspend_fn patrol` would lower to, written by
//     hand: a program counter plus the saved locals per suspend function,
//     with a nested callee's state inside its caller's.
//  2b. flat coroutine: the same, with the nested calls merged into one
//     program counter, as a lowering that inlines them would emit.
//  3. thread: the patrol as straight-line code in a thread_fn, where
//     "wait for the next frame" is a reply on one queue and a blocking
//     qget on another. This is how a blocking patrol can be written today.
//
// Build and run (threads need a real C compiler):
//   goose build patrol.goose && ./patrol [guards] [frames] [thread_frames]

import std;
import os;
import vec;

let STEPS = 20;
let REST = 30;

struct Guard { pos: int2, post: int2, home: int2 }

var frame_no: i64 = 0;

fn step_toward(from: int2, to: int2, s: i32) -> int2 {
    int2 { from.x + (to.x - from.x) * s / STEPS, from.y + (to.y - from.y) * s / STEPS }
}

fn make_guards(n: i64) -> Guard[>..] {
    var gs: Guard[>..] = [];
    for i in n {
        let k = i as! i32;
        let home = int2 { k % 1000, k / 1000 };
        gs.push(Guard { pos: home, post: int2 { home.x + 7 + k % 13, home.y + 3 + k % 5 }, home: home });
    }
    return gs;
}

fn checksum(gs: Guard[:]) -> i64 {
    var h: i64 = 0;
    for g in gs { h = h * 31 + g.pos.x * 7 + g.pos.y; h = h % 1000000007; }
    return h;
}

// 1. The hand-written state machine.

enum GuardState { Walking { from: int2, target: int2, s: i32 }, Resting { until: i64 } }

struct GuardSM { g: Guard, state: GuardState, going_home: bool }

fn start_walk(m: GuardSM&) {
    let target = if m.going_home { m.g.home } else { m.g.post };
    m.state = GuardState.Walking { from: m.g.pos, target: target, s: 1 };
}

fn tick(m: GuardSM&) {
    loop {
        match m.state {
            Walking w => {
                if w.s <= STEPS {
                    m.g.pos = step_toward(w.from, w.target, w.s);
                    m.state = GuardState.Walking { from: w.from, target: w.target, s: w.s + 1 };
                    return;
                }
                m.state = GuardState.Resting { until: frame_no + REST };
            },
            Resting r => {
                if frame_no < r.until { return; }
                m.going_home = !m.going_home;
                start_walk(m);
            },
        }
    }
}

fn run_state_machine(n: i64, frames: i64) -> i64 {
    var ms: GuardSM[>..] = [];
    for g in make_guards(n) {
        let m .= ms.push(GuardSM { g: g, state: GuardState.Resting { until: 0 }, going_home: false });
        start_walk(m);
    }
    frame_no = 0;
    for f in frames {
        for &m in ms { tick(m); }
        frame_no++;
    }
    var h: i64 = 0;
    for m in ms { h = h * 31 + m.g.pos.x * 7 + m.g.pos.y; h = h % 1000000007; }
    return h;
}

// 2. What the compiler would generate for:
//
//   suspend_fn patrol(g: Guard&) {
//       loop { walk_to(g, g.post); rest(REST); walk_to(g, g.home); rest(REST); }
//   }
//   suspend_fn walk_to(g: Guard&, target: int2) {
//       let from = g.pos;
//       for s in 1..STEPS + 1 { g.pos = step_toward(from, target, s); suspend(); }
//   }
//   suspend_fn rest(n: i64) {
//       let until = frame_no + n;
//       while frame_no < until { suspend(); }
//   }
//
// Each suspend function becomes a struct of its program counter and the
// locals live across a suspension, and a resume function that returns true
// once the function has finished.

struct WalkCo { pc: i32, target: int2, from: int2, s: i32 }

fn walk_resume(c: WalkCo&, g: Guard&) -> bool {
    if c.pc == 0 { c.from = g.pos; c.s = 1; c.pc = 1; }
    else if c.pc == 1 { c.s++; }                     // back from suspend(): next iteration
    else { return true; }
    if c.s <= STEPS { g.pos = step_toward(c.from, c.target, c.s); return false; }
    c.pc = 2;
    return true;
}

struct RestCo { pc: i32, n: i64, until: i64 }

fn rest_resume(c: RestCo&) -> bool {
    if c.pc == 0 { c.until = frame_no + c.n; c.pc = 1; }
    else if c.pc != 1 { return true; }
    if frame_no < c.until { return false; }
    c.pc = 2;
    return true;
}

struct PatrolCo { pc: i32, w: WalkCo, r: RestCo }   // the callee states nest inside

fn patrol_resume(c: PatrolCo&, g: Guard&) -> bool {
    loop {
        match c.pc {
            0 => { c.w = WalkCo { pc: 0, target: g.post, .. }; c.pc = 1; },
            1 => {
                if !walk_resume(c.w, g) { return false; }
                c.r = RestCo { pc: 0, n: REST, .. };
                c.pc = 2;
            },
            2 => {
                if !rest_resume(c.r) { return false; }
                c.w = WalkCo { pc: 0, target: g.home, .. };
                c.pc = 3;
            },
            3 => {
                if !walk_resume(c.w, g) { return false; }
                c.r = RestCo { pc: 0, n: REST, .. };
                c.pc = 4;
            },
            _ => {
                if !rest_resume(c.r) { return false; }
                c.pc = 0;
            },
        }
    }
}

fn run_coroutines(n: i64, frames: i64) -> i64 {
    var guards = make_guards(n);
    var cos: PatrolCo[>..] = [];
    for i in n { cos.push(PatrolCo { pc: 0, .. }); }   // co_start(patrol, guards[i])
    frame_no = 0;
    for f in frames {
        for i in n { patrol_resume(cos[i], guards[i]); }   // co_resume
        frame_no++;
    }
    return checksum(guards);
}

// 2b. The same coroutine as a lowering that inlines walk_to and rest into
// patrol would emit it: one program counter, one state per suspension
// point, and the locals of all of them in one struct.

struct FlatCo { pc: i32, from: int2, s: i32, until: i64 }

fn flat_resume(c: FlatCo&, g: Guard&) {
    loop {
        match c.pc {
            0, 2 => {                                   // in walk_to(g.post) or walk_to(g.home)
                if c.s <= STEPS {
                    let target = if c.pc == 0 { g.post } else { g.home };
                    g.pos = step_toward(c.from, target, c.s);
                    c.s++;
                    return;
                }
                c.until = frame_no + REST;
                c.pc++;
            },
            _ => {                                      // in rest(REST)
                if frame_no < c.until { return; }
                c.pc = (c.pc + 1) % 4;
                c.from = g.pos;
                c.s = 1;
            },
        }
    }
}

fn run_flat_coroutines(n: i64, frames: i64) -> i64 {
    var guards = make_guards(n);
    var cos: FlatCo[>..] = [];
    for g in guards { cos.push(FlatCo { pc: 0, from: g.pos, s: 1, .. }); }
    frame_no = 0;
    for f in frames {
        for i in n { flat_resume(cos[i], guards[i]); }
        frame_no++;
    }
    return checksum(guards);
}

// 3. One worker thread per guard, written as straight-line code. Every
// suspension is a reply to main and a blocking wait for the next frame.

struct Tick  { frame: i64 }                 // < 0: stop
struct Reply { x: i32, y: i32 }

thread_fn guard_thread(home: int2, post: int2) {
    var g = Guard { pos: home, post: post, home: home };
    var frame = qget<Tick>().frame;
    fn suspend() -> bool {                  // false once main says stop
        qput(Reply { g.pos.x, g.pos.y });
        frame = qget<Tick>().frame;
        return frame >= 0;
    }
    fn walk_to(target: int2) -> bool {
        let from = g.pos;
        for s: i32 in 1..STEPS + 1 {
            g.pos = step_toward(from, target, s);
            if !suspend() { return false; }
        }
        return true;
    }
    fn rest(n: i64) -> bool {
        let until = frame + n;
        while frame < until { if !suspend() { return false; } }
        return true;
    }
    while walk_to(g.post) && rest(REST) && walk_to(g.home) && rest(REST) {}
}

fn run_threads(n: i64, frames: i64) -> i64 {
    let gs = make_guards(n);
    var ids: i64[>..] = [];
    for g in gs { ids.push(thread_spawn(guard_thread, g.home, g.post)); }
    var last: Reply[>..] = [];
    for i in n { last.push(Reply { 0, 0 }); }
    for f in frames {
        for i in n { qput(Tick { f }); }
        for i in n { last[i] = qget<Reply>(); }      // with n > 1 the order is arbitrary
    }
    for i in n { qput(Tick { -1 }); }
    for id in ids { thread_wait(id); }
    var h: i64 = 0;
    for r in last { h = h * 31 + r.x * 7 + r.y; h = h % 1000000007; }
    return h;
}

fn arg_or(i: i64, fallback: i64) -> i64 {
    if arg_count() <= i { return fallback; }
    var s: u8[>..] = [];
    arg(i, s);
    let v, ok = parse_int(s);
    return if ok { v } else { fallback };
}

fn time_ms() -> f64 { clock_ns() / 1000000.0 }
fn r2(x: f64) -> f64 { (x * 100.0 + 0.5) as! i64 / 100.0 }

let REPS = 5;

fn main() {
    let guards = arg_or(1, 10000);
    let frames = arg_or(2, 10000);
    let thread_frames = arg_or(3, 100037);       // not a whole number of patrols

    // The best of REPS runs of each, interleaved.
    var sm_ms = 1.0e30;
    var co_ms = 1.0e30;
    var h1: i64 = 0;
    var h2: i64 = 0;
    var fl_ms = 1.0e30;
    var h5: i64 = 0;
    for rep in REPS {
        var t = time_ms();
        h1 = run_state_machine(guards, frames);
        sm_ms = min(sm_ms, time_ms() - t);
        t = time_ms();
        h2 = run_coroutines(guards, frames);
        co_ms = min(co_ms, time_ms() - t);
        t = time_ms();
        h5 = run_flat_coroutines(guards, frames);
        fl_ms = min(fl_ms, time_ms() - t);
    }
    let per = (guards * frames) as f64 / 1000000.0;
    print("many guards: ", guards, " guards x ", frames, " frames, best of ", REPS);
    print("  state machine  ", r2(sm_ms), " ms  ", r2(sm_ms / per), " ns per guard-frame  checksum ", h1);
    print("  coroutine      ", r2(co_ms), " ms  ", r2(co_ms / per), " ns per guard-frame  checksum ", h2);
    print("  flat coroutine ", r2(fl_ms), " ms  ", r2(fl_ms / per), " ns per guard-frame  checksum ", h5);
    var cos: PatrolCo[>..] = [];
    cos.push(PatrolCo { pc: 0, .. });
    var flat: FlatCo[>..] = [];
    flat.push(FlatCo { pc: 0, .. });
    var sms: GuardState[>..] = [];
    sms.push(GuardState.Resting { until: 0 });
    print("  state per guard: state machine ", bytes_of(sms).len + 1, " bytes (enum + flag), coroutine ",
          bytes_of(cos).len, ", flat coroutine ", bytes_of(flat).len);

    var c1_ms = 1.0e30;
    var th_ms = 1.0e30;
    var h3: i64 = 0;
    var h4: i64 = 0;
    for rep in REPS {
        var t = time_ms();
        h3 = run_coroutines(1, thread_frames);
        c1_ms = min(c1_ms, time_ms() - t);
        t = time_ms();
        h4 = run_threads(1, thread_frames);
        th_ms = min(th_ms, time_ms() - t);
    }
    let per1 = thread_frames as f64 / 1000000.0;
    print("one guard: ", thread_frames, " frames, best of ", REPS);
    print("  coroutine      ", r2(c1_ms), " ms  ", r2(c1_ms / per1), " ns per frame  checksum ", h3);
    print("  thread         ", r2(th_ms), " ms  ", r2(th_ms / per1), " ns per frame  checksum ", h4);
    print("  workers this runtime allows at once: ", hardware_threads());
}
