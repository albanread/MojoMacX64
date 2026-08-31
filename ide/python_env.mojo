# Project Python environments for Roast.
#
# Python called from Mojo is not another service. std.python dlopens libpython
# into the Mojo program and initializes CPython there.  Roast therefore owns
# two distinct paths:
#
#   MOJO_PYTHON_LIBRARY  the bundled library loaded into the Mojo process
#   MOJO_PYTHON          the project venv's interpreter, used by KGEN to set
#                        PYTHONEXECUTABLE and expose its site-packages
#
# PYTHONHOME points CPython back at the bundled standard library.  It matters
# for a relocated framework: a Homebrew-built interpreter otherwise remembers
# the prefix it was built under even after it has been copied into Roast.app.
#
# Venvs are mutable and an app bundle is signed, so they cannot live together.
# NSSearchPathForDirectoriesInDomains (through session.support_dir) gives the
# macOS-approved per-user Application Support directory and will also do the
# right thing if Roast is sandboxed later.
from std.hashlib._fnv1a import Fnv1a
from std.objc import Cls, Obj, ObjCObject, autoreleasepool, nsstring
from std.os import getenv, listdir

from json import JSON
import session


def _exists(path: String) -> Bool:
    if path == "":
        return False
    with autoreleasepool():
        let fm = Cls["NSFileManager"]().defaultManager()
        var p = path
        return Obj["NSFileManager"](fm.addr()).fileExistsAtPath(
            nsstring(p).ptr()
        )


def _ensure_dir(path: String) -> Bool:
    if path == "":
        return False
    with autoreleasepool():
        let fm = Cls["NSFileManager"]().defaultManager()
        var p = path
        return Obj["NSFileManager"](
            fm.addr()
        ).createDirectoryAtPath_withIntermediateDirectories_attributes_error(
            nsstring(p).ptr(), True, ObjCObject(0).ptr(), ObjCObject(0).ptr()
        )


def dirname(path: String) -> String:
    let cut = path.rfind("/")
    if cut <= 0:
        return String()
    return String(path[byte=0:cut])


def basename(path: String) -> String:
    let cut = path.rfind("/")
    return String(path[byte=cut + 1:]) if cut >= 0 else path


def _read_file(path: String) -> String:
    try:
        with open(path, "r") as f:
            return String(f.read().strip())
    except:
        return String()


def project_location(root: String, current: String) -> String:
    """The stable directory whose Python packages belong to this launch."""
    if root != "":
        return root
    return dirname(current)


def project_key(project: String) -> String:
    """A stable, filesystem-safe key without putting source paths in filenames."""
    if project == "":
        return String()
    return hex(hash[Fnv1a](project), prefix="")


def environments_root() -> String:
    """The mutable Python root, overridable so tests touch no user state."""
    let override = getenv("ROAST_PYTHON_ENV_ROOT")
    if override != "":
        _ = _ensure_dir(override)
        return override^
    let support = session.support_dir()
    if support == "":
        return String()
    let root = support + String("/Python/Environments")
    _ = _ensure_dir(root)
    return root^


def runtime_version(toolchain_root: String) -> String:
    let override = getenv("ROAST_PYTHON_VERSION")
    if override != "":
        return override^
    let resources = dirname(toolchain_root)
    if resources != "":
        let recorded = _read_file(resources + String("/Python/VERSION"))
        if recorded != "":
            return recorded^
    let home = runtime_home(toolchain_root)
    if home != "":
        let leaf = basename(home)
        if leaf != "Current":
            return leaf^
    return String("external")


def environment_dir(project: String, toolchain_root: String = String()) -> String:
    let root = environments_root()
    let key = project_key(project)
    if root == "" or key == "":
        return String()
    return (
        root
        + String("/")
        + key
        + String("/py-")
        + runtime_version(toolchain_root)
    )


def environment_python(project: String, toolchain_root: String = String()) -> String:
    let env = environment_dir(project, toolchain_root)
    return env + String("/bin/python") if env != "" else String()


def environment_ready(project: String, toolchain_root: String = String()) -> Bool:
    let env = environment_dir(project, toolchain_root)
    return (
        env != ""
        and _exists(env + String("/pyvenv.cfg"))
        and _exists(env + String("/bin/python"))
    )


def project_uses_python(project: String) -> Bool:
    """Does this project actually speak Python?

    Run and Debug used to build a venv for EVERY project before doing
    anything else -- the fern example, three files of pure Mojo, got a
    private Python installation it would never import. The venv is wanted
    exactly when one of these holds, any one sufficient:

      * requirements.txt or pyproject.toml at the root -- the same two
        files the dependency installer itself honours
      * a .py file anywhere in the tree
      * a .mojo file that mentions std.python -- the only door to the
        interpreter in this dialect, so its absence is proof

    The walk is bounded (four levels, 200 sources read, 500 entries
    considered) and skips what is never source: build, .git, .venv,
    __pycache__. Two failure directions, deliberately asymmetric: the
    ROOT being unreadable means nothing can be known, so the answer is
    the safe True -- a needless venv is the old behaviour, merely
    wasteful, where a wrongly skipped one breaks a real Python project
    at runtime. A CHILD that will not list is just a plain file
    (LICENSE, Makefile) met by a walk that descends anything, and says
    nothing about Python at all.
    """
    if project == "":
        return True
    if _exists(project + String("/requirements.txt")):
        return True
    if _exists(project + String("/pyproject.toml")):
        return True

    # Iterative: paths and depths in parallel lists. Bounded work, and
    # recursion through raising functions is a door this compiler has
    # already slammed once.
    var dirs = List[String]()
    var depths = List[Int]()
    dirs.append(project)
    depths.append(0)
    var read_files = 0
    var considered = 0
    while len(dirs) > 0:
        let dir = dirs.pop()
        let depth = depths.pop()
        var names = List[String]()
        var listed = True
        try:
            names = listdir(dir)
        except:
            listed = False
        if not listed:
            if depth == 0:
                return True  # the project itself is unreadable: assume
            continue  # a plain file the walk tried as a directory
        for i in range(len(names)):
            let name = names[i]
            if name.startswith("."):
                continue
            if name == "build" or name == "__pycache__" or name == "node_modules":
                continue
            considered += 1
            if considered > 500:
                return True  # too big to be sure: the safe answer
            let path = dir + String("/") + name
            if name.endswith(".py"):
                return True
            if name.endswith(".mojo"):
                read_files += 1
                if read_files > 200:
                    return True
                if _read_file(path).find(String("std.python")) >= 0:
                    return True
            elif depth < 4:
                # Descend everything else. If it turns out to be a plain
                # file, its listdir fails soft above.
                dirs.append(path)
                depths.append(depth + 1)
    return False


def runtime_home(toolchain_root: String) -> String:
    """The relocatable CPython prefix that belongs to this toolchain.

    ROAST_PYTHON_HOME and python.home make a bare development build
    testable; a shipped installation needs neither.

    Two layouts, in order. Python lives INSIDE the toolchain now
    (`<toolchain>/Python`), which is where make-dist puts it and where
    bin/python3 reaches it. It used to live BESIDE it, when a fat Roast.app
    carried both in its Resources -- checked second so an old bundle still
    works.
    """
    let override = getenv("ROAST_PYTHON_HOME")
    if override != "" and _exists(override + String("/bin/python3")):
        return override^
    let chosen = session.setting(String("python.home"))
    if chosen != "" and _exists(chosen + String("/bin/python3")):
        return chosen^
    if toolchain_root == "":
        return String()
    comptime FRAMEWORK = "/Python/Python.framework/Versions/Current"
    let inside = toolchain_root + String(FRAMEWORK)
    if _exists(inside + String("/bin/python3")):
        return inside^
    let beside = dirname(toolchain_root)
    if beside == "":
        return String()
    let bundled = beside + String(FRAMEWORK)
    # The bundled interpreter, or nothing. Roast does NOT go looking for a
    # Python on the machine: the interop links against a specific libpython
    # ABI, and a version that merely happens to be installed is how you get
    # a crash at the first `import` rather than an honest refusal here.
    # Installing it is the person's choice, and declining is answered by
    # turning the feature off -- not by substituting something else.
    return bundled^ if _exists(bundled + String("/bin/python3")) else String()


def runtime_origin(toolchain_root: String) -> String:
    """Where the interpreter in use came from, for anything that reports
    it. A person who declined the bundled Python and got one anyway should
    be able to find out which one answered."""
    let home = runtime_home(toolchain_root)
    if home == "":
        return String("none")
    if home.startswith(toolchain_root + String("/Python/")) or home.startswith(
        dirname(toolchain_root) + String("/Python/")
    ):
        return String("bundled")
    if getenv("ROAST_PYTHON_HOME") == home:
        return String("ROAST_PYTHON_HOME")
    if session.setting(String("python.home")) == home:
        return String("chosen in settings")
    return String("unknown")


def runtime_python(toolchain_root: String) -> String:
    let home = runtime_home(toolchain_root)
    return home + String("/bin/python3") if home != "" else String()


def runtime_library(toolchain_root: String) -> String:
    let chosen = session.setting(String("python.library"))
    if chosen != "" and _exists(chosen):
        return chosen^
    let home = runtime_home(toolchain_root)
    if home == "":
        return String()
    let framework = home + String("/Python")
    return framework^ if _exists(framework) else String()


def runtime_available(toolchain_root: String) -> Bool:
    return (
        runtime_python(toolchain_root) != ""
        and runtime_library(toolchain_root) != ""
    )


def _base_variables(toolchain_root: String) -> JSON:
    var vars = JSON.object()
    let home = runtime_home(toolchain_root)
    if home == "":
        return vars^
    vars.set(String("PYTHONHOME"), JSON(home))
    vars.set(String("PYTHONNOUSERSITE"), JSON(String("1")))
    let path = getenv("PATH")
    let bin = home + String("/bin")
    vars.set(
        String("PATH"),
        JSON(bin + (String(":") + path if path != "" else String())),
    )
    return vars^


def bootstrap_variables(toolchain_root: String) -> JSON:
    """Environment used while the bundled interpreter creates a venv."""
    return _base_variables(toolchain_root)


def variables(project: String, toolchain_root: String) -> JSON:
    """Environment that makes std.python use this project's managed venv."""
    if not environment_ready(project, toolchain_root):
        return JSON.object()
    var vars = _base_variables(toolchain_root)
    let env = environment_dir(project, toolchain_root)
    let python = environment_python(project, toolchain_root)
    let library = runtime_library(toolchain_root)
    if python == "" or library == "":
        return vars^
    vars.set(String("MOJO_PYTHON"), JSON(python))
    vars.set(String("MOJO_PYTHON_LIBRARY"), JSON(library))
    vars.set(String("VIRTUAL_ENV"), JSON(env))
    let inherited = getenv("PATH")
    vars.set(
        String("PATH"),
        JSON(env + String("/bin") + (String(":") + inherited if inherited != "" else String())),
    )
    return vars^


def pip_variables(project: String, toolchain_root: String) -> JSON:
    var vars = variables(project, toolchain_root)
    vars.set(String("PIP_REQUIRE_VIRTUALENV"), JSON(String("1")))
    vars.set(String("PIP_DISABLE_PIP_VERSION_CHECK"), JSON(String("1")))
    return vars^


def package_arguments(var requirement: String, project: String) -> List[String]:
    """Arguments for one requirement, or `-r relative/requirements.txt`."""
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("pip"))
    args.append(String("install"))
    let text = String(requirement.strip())
    if text.startswith("-r "):
        var path = String(text[byte=3:].strip())
        if path != "" and not path.startswith("/") and project != "":
            path = project + String("/") + path
        args.append(String("-r"))
        args.append(path^)
    elif text != "":
        args.append(text)
    return args^


def project_dependency_arguments(project: String) -> List[String]:
    """Prefer an explicit requirements file; otherwise install pyproject."""
    let requirements = project + String("/requirements.txt")
    if project != "" and _exists(requirements):
        return package_arguments(String("-r requirements.txt"), project)
    var args = List[String]()
    if project != "" and _exists(project + String("/pyproject.toml")):
        args.append(String("-m"))
        args.append(String("pip"))
        args.append(String("install"))
        args.append(String("-e"))
        args.append(project)
    return args^
