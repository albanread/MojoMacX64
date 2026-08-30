#!/usr/bin/env bash
# Copy a relocatable, in-process CPython runtime into a Roast Resources folder.
#
#   tools/bundle-python.sh DEST [PYTHON]
#
# DEST receives Python.framework. PYTHON defaults to ROAST_PYTHON or python3.
# A framework build is required: Mojo loads its Python library in-process, and
# the matching executable is also what creates/manages each project venv.
set -euo pipefail

DEST="${1:?usage: bundle-python.sh DEST [PYTHON]}"
PYTHON_BIN="${2:-${ROAST_PYTHON:-$(command -v python3 || true)}}"
[ -x "$PYTHON_BIN" ] || { echo "no Python interpreter found" >&2; exit 1; }

PYVER="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
FRAMEWORKS="$($PYTHON_BIN -c 'import sysconfig; print(sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX") or "")')"
SOURCE="$FRAMEWORKS/Python.framework"
[ -f "$SOURCE/Versions/$PYVER/Python" ] || {
  echo "$PYTHON_BIN is not a macOS framework build of Python" >&2
  exit 1
}

TARGET="$DEST/Python.framework"
VERSION="$TARGET/Versions/$PYVER"
# The interpreter INSIDE the copied framework. Homebrew ships `python3.12`
# and no unsuffixed `python3`; python.org's build ships both. Name whichever
# is actually there rather than assuming, or every use below fails with "No
# such file or directory" on a framework that copied perfectly.
pybin() {
  if [ -x "$VERSION/bin/python3" ]; then echo "$VERSION/bin/python3"
  else echo "$VERSION/bin/python$PYVER"; fi
}
LIB="$VERSION/lib"
LICENSES="$DEST/Licenses"

rm -rf "$TARGET" "$LICENSES"
mkdir -p "$DEST" "$LICENSES"
rsync -a --exclude '__pycache__/' "$SOURCE/" "$TARGET/"
printf '%s\n' "$PYVER" > "$DEST/VERSION"

# Make the framework a FRAMEWORK. Homebrew's Python.framework ships only
# Versions/<v>/ -- no Versions/Current, and none of the top-level symlinks a
# macOS framework is defined by. python.org's build ships all of them, which
# is why this never came up on the other machine.
#
# codesign requires the canonical shape and refuses the whole bundle without
# it, with a sentence that names no cause:
#
#   Python.framework: bundle format unrecognized, invalid, or unsuitable
#
# Everything needed is already inside Versions/<v>; only the links are absent.
# Created rather than assumed, and only when missing, so a well-formed source
# framework is left exactly as it was.
ln -sfn "$PYVER" "$TARGET/Versions/Current"
for link in Python Resources Headers; do
  [ -e "$VERSION/$link" ] && ln -sfn "Versions/Current/$link" "$TARGET/$link"
done

# And an unsuffixed `python3`, for the same reason. Homebrew's bin holds
# python3.12 and nothing else; python.org's holds both. Everything downstream
# names the unsuffixed one -- bin/python3 in the distribution, Roast's
# python_env, any venv a project makes -- so it is created here once rather
# than taught to each of them.
[ -e "$VERSION/bin/python3" ] || ln -sfn "python$PYVER" "$VERSION/bin/python3"
# CPython's regression suite is not part of an embedded runtime and is roughly
# half of the standard-library payload. ensurepip, venv, headers and config
# files stay: pip may need all of them to build a source distribution.
rm -rf "$VERSION/lib/python$PYVER/test"

is_macho() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

macho_files() {
  find "$TARGET" -type f -print0
}

is_system_dependency() {
  case "$1" in
    /System/Library/*|/usr/lib/*|@*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_license() {
  dep="$1"
  prefix="${dep%%/lib/*}"
  [ "$prefix" != "$dep" ] || return 0
  license="$(find -L "$prefix" -maxdepth 2 -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -print 2>/dev/null | head -1 || true)"
  [ -n "$license" ] || return 0
  cp -f "$license" "$LICENSES/$(basename "$prefix")-$(basename "$license")"
}

# Copy the non-system dylib closure used by stdlib extension modules. A
# Homebrew Python otherwise appears bundled but imports such as ssl, sqlite3,
# decimal and lzma still reach back into /opt/homebrew.
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      is_system_dependency "$dep" && continue
      case "$dep" in
        *Python.framework/Versions/$PYVER/Python) continue ;;
      esac
      [ -f "$dep" ] || continue
      out="$LIB/$(basename "$dep")"
      if [ ! -f "$out" ]; then
        cp -L "$dep" "$out"
        chmod u+w "$out"
        copy_license "$dep"
        changed=1
      fi
    done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/')
  done < <(macho_files)
done

relocated_dependency() {
  consumer="$1"
  name="$2"
  case "$consumer" in
    "$VERSION"/lib/python$PYVER/lib-dynload/*)
      printf '@loader_path/../../%s' "$name" ;;
    "$VERSION"/lib/*)
      printf '@loader_path/%s' "$name" ;;
    "$VERSION"/bin/*)
      printf '@executable_path/../lib/%s' "$name" ;;
    "$VERSION"/Resources/Python.app/Contents/MacOS/*)
      printf '@executable_path/../../../../lib/%s' "$name" ;;
    *)
      printf '@loader_path/%s' "$name" ;;
  esac
}

# Relocate the framework reference in its launchers and every copied absolute
# dylib reference. Direct @loader_path/@executable_path references avoid
# relying on rpaths inherited from the packaging machine.
while IFS= read -r -d '' binary; do
  is_macho "$binary" || continue
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      *Python.framework/Versions/$PYVER/Python)
        [ "$binary" = "$VERSION/Python" ] && continue
        case "$binary" in
          "$VERSION"/bin/*) replacement='@executable_path/../Python' ;;
          "$VERSION"/Resources/Python.app/Contents/MacOS/*)
            replacement='@executable_path/../../../../Python' ;;
          *) replacement='@loader_path/Python' ;;
        esac
        install_name_tool -change "$dep" "$replacement" "$binary" 2>/dev/null
        ;;
      /*)
        is_system_dependency "$dep" && continue
        replacement="$(relocated_dependency "$binary" "$(basename "$dep")")"
        install_name_tool -change "$dep" "$replacement" "$binary" 2>/dev/null
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/')
done < <(macho_files)

install_name_tool -id "@rpath/Python.framework/Versions/$PYVER/Python" \
  "$VERSION/Python" 2>/dev/null
while IFS= read -r -d '' dylib; do
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib" 2>/dev/null
done < <(find "$LIB" -maxdepth 1 -type f -name '*.dylib' -print0)

# Apple's bundle rules forbid a symlink that leaves the bundle, and
# codesign --verify --strict rejects the whole framework over it with the
# unhelpful "No such file or directory" (--strict=symlinks names it). The
# relocatable build ships
#   Versions/<v>/lib/python<v>/site-packages -> ../../../../../../lib/...
# which points at <toolchain>/lib/python$PYVER/site-packages -- a path that
# does not exist here and never has. Nothing can depend on a link that has
# always dangled, so it becomes the real directory it was pretending to be:
# the framework is then self-contained and pip has somewhere to install.
SP="$DEST/Python.framework/Versions/Current/lib/python$PYVER/site-packages"
if [ -L "$SP" ]; then
  rm "$SP"
  mkdir -p "$SP"
  echo "   site-packages: escaping symlink replaced with a real directory"
fi

# A copied Homebrew interpreter contains its build prefix. PYTHONHOME is the
# relocation contract Roast supplies both to venv/pip and to the Mojo program.
# Sign every Mach-O before sealing the framework. `codesign --deep` discovers
# nested bundles but does not reliably replace signatures on loose extension
# modules, and dyld kills the interpreter the first time one of those is read.
# The outer app packaging signs the final bundle again.
while IFS= read -r -d '' binary; do
  is_macho "$binary" || continue
  codesign --force --sign - --timestamp=none "$binary" >/dev/null 2>&1
done < <(macho_files)
# Bytecode caches must exist before the seal and after the signatures.
# Relocation rewrites the Mach-O headers, which invalidates the ad-hoc
# signature the interpreter was built with, and the kernel then SIGKILLs it
# on exec -- so compileall cannot run until the loop above has re-signed
# everything. Run here, the caches are covered when the bundle is sealed
# below: imports are fast and the signature stays valid. Left to itself the
# interpreter would write them on first import, into a signed framework.
find "$TARGET" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
PYTHONHOME="$VERSION" "$(pybin)" -m compileall -q -f \
  "$VERSION/lib/python$PYVER" >/dev/null || {
  echo "   compileall failed -- the stdlib would be sealed without bytecode" >&2
  exit 1
}

codesign --force --deep --sign - --timestamp=none "$TARGET" >/dev/null 2>&1

bad="$(
  while IFS= read -r -d '' binary; do
    is_macho "$binary" || continue
    otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*([^ ]+).*/\1/'
  done < <(macho_files) |
    grep '^/' | grep -vE '^(/System/Library/|/usr/lib/)' || true
)"
[ -z "$bad" ] || {
  echo "absolute non-system Python dependencies remain:" >&2
  printf '  %s\n' "$bad" >&2
  exit 1
}

# The smoke test runs AFTER the framework is sealed, so it must not write
# into it. Importing a module writes __pycache__ beside the source by
# default, which adds files the seal does not cover and makes codesign
# report the framework as invalid. The interpreter is told not to.
SMOKE="$(mktemp -d)"
trap 'rm -rf "$SMOKE"' EXIT
export PYTHONDONTWRITEBYTECODE=1
PYTHONHOME="$VERSION" "$(pybin)" -c \
  'import ssl, sqlite3, venv; print("python", __import__("sys").version.split()[0], ssl.OPENSSL_VERSION, sqlite3.sqlite_version)'
PYTHONHOME="$VERSION" "$(pybin)" -m venv "$SMOKE/env"
PYTHONHOME="$VERSION" "$SMOKE/env/bin/python" -m pip --version

echo "   CPython $PYVER: $(du -sh "$DEST" | cut -f1), relocatable, venv + pip OK"
