# Integration probe used by tools/make-app.sh after it creates a real venv.
# Its value is that Python is imported through Mojo, not by invoking python:
# libpython and the project site-packages must both be configured correctly.
from std.python import Python


def main() raises:
    let sys = Python.import_module("sys")
    let marker = Python.import_module("roast_managed_test")
    print("prefix:", String(sys.prefix))
    print("base:", String(sys.base_prefix))
    print("marker:", String(marker.VALUE))
