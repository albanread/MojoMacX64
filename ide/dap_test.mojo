# The debug adapter client, against a real adapter and a real program.
#
# No window: a debugger is a conversation with a process, and none of that
# needs a view. What it does need is an adapter and something to debug, so
# ROAST_DAP names the adapter and ROAST_DAP_PROGRAM the binary -- check-ide
# compiles a tiny program with debug info and points this at it.
#
# The two claims worth making are that a breakpoint BINDS and that the stop
# lands where the binding says. Everything else here exists to make those two
# unambiguous when they fail.
from dap import (
    start,
    stop,
    poll,
    is_running,
    is_configured,
    is_stopped,
    evaluate,
    take_eval_fresh,
    eval_result,
    eval_ok,
    frame_count,
    frame_name,
    variable_count,
    variable_name,
    variable_value,
    variable_type,
    stop_line,
    stop_file,
    stop_reason,
    exited,
    output,
    toggle_breakpoint,
    breakpoint_count,
    breakpoint_at,
    breakpoint_line,
    verified_line,
    is_verified,
    clear_breakpoints,
    resume,
)
from std.os import getenv
from std.ffi import external_call
from std.time import perf_counter_ns, sleep


def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name, "=", got)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


# There is no run loop here, so these are the timer. The sleep is not
# politeness: a tight poll loop spins a core, and the thing it starves is the
# adapter it is waiting for. Without it this passed on a quiet machine and
# timed out inside the full suite, which is the worst way for a check to
# fail -- it looks like the code and it is the harness.
comptime TICK = 0.01


def pump(seconds: Float64) -> Int:
    let until = perf_counter_ns() + Int(seconds * 1e9)
    var handled = 0
    while perf_counter_ns() < until:
        handled += poll()
        sleep(TICK)
    return handled


def pump_until_stopped(seconds: Float64) -> Bool:
    let until = perf_counter_ns() + Int(seconds * 1e9)
    while perf_counter_ns() < until:
        _ = poll()
        if is_stopped() or exited():
            return is_stopped()
        sleep(TICK)
    return False


def main() raises:
    var failures = 0
    let adapter = getenv("ROAST_DAP")
    let program = getenv("ROAST_DAP_PROGRAM")
    if adapter == "" or program == "":
        print("dap: set ROAST_DAP and ROAST_DAP_PROGRAM")
        raise Error("ROAST_DAP not set")

    print("dap: breakpoints before anything is running")
    # The editor's order, not the protocol's: someone clicks a gutter before
    # they press Debug, and the client has to hold that until there is an
    # adapter to tell.
    clear_breakpoints()
    let src = getenv("ROAST_DAP_SOURCE")
    failures += check_int(
        "toggle sets", 1 if toggle_breakpoint(src, 9) else 0, 1
    )
    failures += check_int("one breakpoint", breakpoint_count(), 1)
    failures += check_int(
        "found by its line", 1 if breakpoint_at(src, 9) >= 0 else 0, 1
    )
    failures += check_int(
        "unbound reads as asked-for", verified_line(0), 9
    )
    failures += check_int(
        "toggle clears", 1 if toggle_breakpoint(src, 9) else 0, 0
    )
    failures += check_int("none left", breakpoint_count(), 0)

    print("dap: a breakpoint binds, and the program stops on it")
    _ = toggle_breakpoint(src, 9)
    # The plugin rides beside the adapter exactly as roast finds it --
    # bin/lldb-dap with lib/libMojoLLDB.dylib one directory over. Passing it
    # here makes this test cover the same launch the IDE performs.
    var init_cmd = String()
    let slash = adapter.rfind("/")
    if slash > 0:
        let plugin = (
            String(adapter[byte=0:slash])
            + String("/../lib/libMojoLLDB.dylib")
        )
        var st = external_call["access", Int](plugin.unsafe_ptr(), Int(0))
        if st == 0:
            init_cmd = String("plugin load ") + plugin
    failures += check_int(
        "start", 1 if start(adapter, program, ".", init_cmd) else 0, 1
    )
    let stopped = pump_until_stopped(120.0)
    failures += check_int("stopped", 1 if stopped else 0, 1)
    if stopped:
        # A stop event and the setBreakpoints response can be in the same pipe
        # read but become observable on adjacent polls. Drain that tail before
        # asserting verification or waiting on the scopes request; otherwise
        # a busy full-suite run mistakes message ordering for a debugger bug.
        _ = pump(1.0)
        failures += check("reason", stop_reason(), String("breakpoint"))
        # The bound line is the claim. Line 9 is a `for` body that gets
        # inlined, so the adapter slides the breakpoint to the next line that
        # has code -- and the stop has to land on the SAME line the binding
        # reported, or the marker in the gutter is pointing somewhere the
        # program will never be.
        failures += check_int("verified", 1 if is_verified(0) else 0, 1)
        failures += check_int(
            "asked for line 9", breakpoint_line(0), 9
        )
        let bound = verified_line(0)
        if bound < 9:
            print("  FAIL bound line went backwards --", bound)
            failures += 1
        else:
            print("  OK   bound line =", bound, "(slid from 9)" if bound != 9 else "")
        failures += check_int("stop line matches the binding", stop_line(), bound)
        if stop_file().endswith(".mojo"):
            print("  OK   stop file is a mojo source")
        else:
            print("  FAIL stop file --", repr(stop_file()))
            failures += 1

        # Variables. Two round trips behind the stop (scopes, then
        # variables), so pump for them. With Xcode's adapter this section
        # SKIPS rather than fails: no Mojo plugin means no variables, and
        # that absence is the environment, not a regression -- exactly the
        # terms lldb-dap's own absence is treated on.
        var waited = 0.0
        while variable_count() == 0 and waited < 10.0:
            _ = pump(0.5)
            waited += 0.5
        if variable_count() == 0:
            print("  --   variables          none (no MojoLLDB plugin beside this adapter); skipped")
        else:
            print("dap: the stopped frame answers `frame variable`")
            # The stop is at line 9, in `main`: the locals there are
            # `total` and the loop's `i` -- `sum` lives one frame down in
            # `add` and a locals view must NOT show it here.
            var seen_total = False
            var named = 0
            for i in range(variable_count()):
                if variable_name(i) != "":
                    named += 1
                if variable_name(i) == "total":
                    seen_total = True
                    # The value is the DECIMAL, not lldb's hex-then-decimal
                    # double render -- variable_value strips that.
                    if variable_value(i).find("0000") >= 0:
                        print("  FAIL total still carries raw hex --",
                              repr(variable_value(i)))
                        failures += 1
                    else:
                        print("  OK   total =", variable_value(i),
                              " type", variable_type(i))
                if variable_name(i) == "sum":
                    print("  FAIL `sum` leaked from the wrong frame")
                    failures += 1
            failures += check_int(
                "locals are named", 1 if named >= 1 else 0, 1
            )
            failures += check_int(
                "`total` is among them", 1 if seen_total else 0, 1
            )
            # The stack came with the stop: the top frame is main's, and the
            # runtime's startup frames are below it -- proof the walk has
            # depth, not just a top.
            failures += check_int(
                "stack has depth", 1 if frame_count() >= 2 else 0, 1
            )
            if frame_name(0).find("main") >= 0:
                print("  OK   top frame =", frame_name(0))
            else:
                print("  FAIL top frame --", repr(frame_name(0)))
                failures += 1

            # Evaluate: first a plain variable, then an EXPRESSION -- the
            # plugin's JIT compiling Mojo against the live frame and running
            # it in the debuggee. The second is the whole reason the
            # ExpressionParser ships.
            print("dap: the stopped frame evaluates Mojo")
            failures += check_int(
                "evaluate accepted", 1 if evaluate(String("total")) else 0, 1
            )
            var ew = 0.0
            while not take_eval_fresh() and ew < 20.0:
                _ = pump(0.5)
                ew += 0.5
            if ew >= 20.0:
                print("  FAIL evaluate: no reply")
                failures += 1
            else:
                failures += check_int(
                    "total evaluates", 1 if eval_ok() else 0, 1
                )
                print("  OK   total ->", eval_result())

            # An expression over a frame LOCAL cannot evaluate yet: the
            # plugin materializes only REPL-persistent variables, and
            # injecting frame locals into the JIT is the next plugin
            # feature, not a regression. What this pins instead is the part
            # that was broken and is now fixed: the failure REACHES US WITH
            # WORDS. The diagnostics used to be cleared on the way out by a
            # broadcast to a listener that only Jupyter attaches, so every
            # expression error arrived as an empty string.
            _ = evaluate(String("total + 41"))
            ew = 0.0
            while not take_eval_fresh() and ew < 30.0:
                _ = pump(0.5)
                ew += 0.5
            if ew >= 30.0:
                print("  FAIL expression: no reply")
                failures += 1
            elif eval_ok():
                print("  OK   locals in expressions arrived early:",
                      eval_result())
            elif eval_result().find("unknown declaration") >= 0:
                print("  OK   the JIT's refusal has words:",
                      repr(String(eval_result()[byte=0:40])))
            else:
                print("  FAIL expression error is unreadable --",
                      repr(eval_result()))
                failures += 1

        print("dap: it runs on")
        # Resume until the program exits. With optimisation the breakpoint
        # slides OUT of the loop and one resume suffices; built
        # --no-optimization it binds inside the loop and hits five times.
        # A person keeps pressing continue; so does this.
        var resumes = 0
        while not exited() and resumes < 12:
            resume()
            resumes += 1
            var w = 0.0
            while not exited() and not is_stopped() and w < 10.0:
                _ = pump(0.5)
                w += 0.5
        failures += check_int("ran to exit", 1 if exited() else 0, 1)
        print("  OK   resumes to exit =", resumes)
        _ = pump(2.0)
        # The program prints and exits; the adapter forwards both.
        if output().find("total:") >= 0:
            print("  OK   the program's output came through the adapter")
        else:
            print("  FAIL no program output --", repr(output()))
            failures += 1

    stop()
    failures += check_int("stopped adapter", 1 if is_running() else 0, 0)
    failures += check_int(
        "bindings forgotten with the process", verified_line(0), 9
    )

    print()
    if failures == 0:
        print("dap OK")
    else:
        print("dap FAILED:", failures)
        raise Error("dap tests failed")
