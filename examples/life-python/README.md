# Life, through Python

Conway's Game of Life again — but this window is **pygame's**, not Cocoa's.
The grid logic is Mojo (`gridv1.mojo`); the rendering calls into Python via
`Python.import_module("pygame")`, running in the CPython this toolchain
carries. Put it beside the native `life` example and the comparison is the
demo: same program, two windowing worlds — and the first thing everyone
says is how much faster the Cocoa one feels. That is the demo working.
(To be fair to Python, upstream's loop also sleeps 0.1s per generation;
to be fair to Cocoa, nobody has ever asked it to slow down.)

## First run

pygame lives in the project's own Python environment, and the project
ships a `requirements.txt` naming it — `pygame-ce`, the community build,
because it publishes wheels for current CPython (classic pygame had none
for 3.14 and tried to compile itself against an SDL nobody has). It
installs as the same `pygame` module. So, once:

1. Python menu → **Create or Repair Environment**
2. Python menu → **Install Project Dependencies**

Then ⌘R. Quit the pygame window to stop.
