#!/usr/bin/env bash
# Package Roast as a Mac application: Roast.app, and a .dmg to hand someone.
#
#   ./tools/make-app.sh              build Roast.app and Roast-<ver>.dmg
#   ./tools/make-app.sh --no-dmg     the bundle only
#   APP_DIR=/tmp/mine ./tools/make-app.sh
#
# Needs a distribution: run ./tools/release.sh first. This does not compile
# anything except Roast itself -- it takes the toolchain the distribution
# already assembled and folds it into a bundle.
#
# WHAT AN APPLICATION HAS TO CARRY
#
# Roast is an IDE, so shipping it means shipping a compiler. Everything the
# editor does beyond typing needs the toolchain: cmd-B runs `cocoamojo`,
# completions and diagnostics come from `mojo-lsp-server`, both need the
# stdlib sources and the Cocoa database, and the Examples menu reads
# share/examples. So the whole distribution goes in Contents/Resources,
# minus one part: include/ is 172 MB of LLVM headers for building out-of-tree
# C++ against the compiler, which no application does.
#
# Mojo's Python interop loads CPython into the Mojo program. The app therefore
# also carries a relocatable Python.framework; project venvs stay in the
# user's Application Support directory, outside this signed bundle.
#
# HOW THE APP FINDS IT
#
# Two mechanisms, one for the loader and one for the program.
#
# The loader: `cocoamojo` bakes an ABSOLUTE rpath into everything it links,
# naming the distribution it built from -- fine on this machine, meaningless
# on anyone else's. The copy in the bundle gets an @executable_path rpath
# added and the absolute one deleted, so it resolves its dylibs wherever the
# .app is dragged.
#
# The program: a double-clicked app inherits no environment, so there is no
# COCOAMOJO_ROOT. `toolchain_root()` in the IDE falls back to asking NSBundle
# where it is, which is why the layout below puts the toolchain exactly at
# Contents/Resources/CocoaMojo and not somewhere prettier.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
D="$ROOT/dist/MojoMacX64"
OUT="${APP_DIR:-$ROOT/dist}"
APP="$OUT/Roast.app"
C="$APP/Contents"

want_dmg=1
[ "${1:-}" = "--no-dmg" ] && want_dmg=0
# THIN=1 builds the app the installer ships: the editor and nothing else.
# The toolchain it talks to is the INSTALLED one, so folding a second copy
# into Resources would ship a gigabyte twice and let the two drift.
THIN="${THIN:-0}"
INSTALLED_LIB="/Applications/Roast/CocoaMojo/current/lib"

[ -x "$D/bin/cocoamojo" ] || {
  echo "no distribution at dist/MojoMacX64 -- run ./tools/release.sh first"
  exit 1
}

VER="$(date +%Y.%m.%d)"
GITREV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== Roast.app =="
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"

# ── the toolchain ──────────────────────────────────────────────────────────
# --delete-excluded as well as --delete, so an include/ left by an earlier
# run cannot survive into a bundle that is supposed to be without one.
if [ "$THIN" = 1 ]; then
  echo "== toolchain =="
  echo "   not bundled: this app talks to $INSTALLED_LIB"
else
  echo "== toolchain =="
  rsync -a --delete --delete-excluded \
        --exclude 'include/' --exclude '.roast.log' \
        "$D/" "$C/Resources/CocoaMojo/"
  echo "   $(du -sh "$C/Resources/CocoaMojo" | cut -f1) (include/ left out)"
fi

# ── in-process Python ──────────────────────────────────────────────────────
# bundle-python copies the framework used to package Roast, closes over its
# non-system dylibs, relocates them, and proves venv + pip before returning.
if [ "$THIN" = 1 ]; then
  echo "== python =="
  echo "   not bundled: the toolchain carries it at <toolchain>/Python,"
  echo "   which is where python_env has always looked for it"
else
  echo "== python =="
  "$ROOT/tools/bundle-python.sh" "$C/Resources/Python"
fi

# ── the executable ─────────────────────────────────────────────────────────
# Built here rather than copied from bin/, so the app always carries the IDE
# at the current source rather than whatever the distribution last assembled.
echo "== roast =="
COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" --build "$ROOT/ide/roast.mojo" \
    -o "$C/MacOS/Roast" >"$OUT/.roast-app.log" 2>&1 || {
  echo "   FAILED -- see $OUT/.roast-app.log"; exit 1
}
rm -f "$OUT/.roast-app.log"

# From Contents/MacOS, the dylibs are two levels up and across. The absolute
# rpath naming this machine's checkout is deleted rather than left as a
# fallback: leaving it means the app works here and only here, and does so
# silently, which is the worst way to find out.
if [ "$THIN" = 1 ]; then
  # An ABSOLUTE rpath, deliberately, and the only one allowed: the dylibs
  # live in the installation and nowhere else, so a relocatable path would
  # be a lie. The check below allows exactly this one.
  install_name_tool -add_rpath "$INSTALLED_LIB" "$C/MacOS/Roast" \
      2>/dev/null || true
else
  install_name_tool -add_rpath "@executable_path/../Resources/CocoaMojo/lib" \
      "$C/MacOS/Roast" 2>/dev/null || true
fi
install_name_tool -delete_rpath "$D/lib" "$C/MacOS/Roast" 2>/dev/null || true
# The compiler also contributes `/lib` as a fallback when its runtime path is
# reduced to a directory. It is not a useful location on macOS, and leaving an
# absolute rpath in a supposedly relocatable bundle makes a local success less
# meaningful than it should be.
install_name_tool -delete_rpath "/lib" "$C/MacOS/Roast" 2>/dev/null || true

rpaths="$(otool -l "$C/MacOS/Roast" | awk '
  /cmd LC_RPATH/ { want_path = 1; next }
  want_path && /path / { print $2; want_path = 0 }
')"
if [ "$THIN" = 1 ]; then
  stray="$(printf '%s\n' "$rpaths" | grep '^/' | grep -vF "$INSTALLED_LIB" || true)"
else
  stray="$(printf '%s\n' "$rpaths" | grep '^/' || true)"
fi
if [ -n "$stray" ]; then
  echo "   FAILED -- absolute rpath remains in Roast:"
  printf '     %s\n' "$stray"
  exit 1
fi
echo "   $(stat -f%z "$C/MacOS/Roast" | awk '{printf "%.0f KB", $1/1024}'), rpath relocated"

# The Python packager proved its interpreter can make a venv. This proves the
# other half: a Mojo process dlopens the bundled library and imports a module
# from that venv, which is the execution model Roast is shipping.
if [ "$THIN" = 1 ]; then
  echo "== mojo + python =="
  echo "   skipped: the installation's CPython is proven by its own build"
else
echo "== mojo + python =="
PYHOME="$C/Resources/Python/Python.framework/Versions/Current"
PYSMOKE="$(mktemp -d)"
PYENV="$PYSMOKE/env"
PYTHONHOME="$PYHOME" "$PYHOME/bin/python3" -m venv "$PYENV"
PYSITE="$(PYTHONHOME="$PYHOME" "$PYENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')"
printf 'VALUE = "managed-venv-ok"\n' > "$PYSITE/roast_managed_test.py"
COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" --build \
  "$ROOT/ide/python_embed_test.mojo" -o "$PYSMOKE/probe" \
  >"$PYSMOKE/build.log" 2>&1 || {
    echo "   FAILED -- Mojo/Python probe did not build"
    grep -m1 'error' "$PYSMOKE/build.log" || true
    rm -rf "$PYSMOKE"
    exit 1
  }
PYOUT="$(
  PYTHONHOME="$PYHOME" \
  MOJO_PYTHON="$PYENV/bin/python" \
  MOJO_PYTHON_LIBRARY="$PYHOME/Python" \
  "$PYSMOKE/probe" 2>&1
)"
if ! printf '%s\n' "$PYOUT" | grep -q 'marker: managed-venv-ok'; then
  echo "   FAILED -- Mojo did not import from the managed venv"
  printf '%s\n' "$PYOUT"
  rm -rf "$PYSMOKE"
  exit 1
fi
echo "   in-process import from managed venv OK"
rm -rf "$PYSMOKE"
fi

# ── the bundle's paperwork ─────────────────────────────────────────────────
# LSMinimumSystemVersion matches what the toolchain needs; NSHighResolution
# because a text editor on a blurry backing store is unusable. The document
# type makes .mojo files openable with Roast from the Finder, which the app
# delegate's application:openFile: actually honours.
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Roast</string>
  <key>CFBundleDisplayName</key>       <string>Roast</string>
  <key>CFBundleExecutable</key>        <string>Roast</string>
  <key>CFBundleIdentifier</key>        <string>org.mojococoa.roast</string>
  <key>CFBundleVersion</key>           <string>$VER</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>
  <!-- Scriptable: the sdef gives Script Editor the words; the events work
       by raw code either way. sdef(1) resolves this only for a BUNDLE -
       measured: the same file embedded in a __TEXT,__sdef section of the
       bare binary reads back byte-identical with segedit yet sdef(1)
       refuses it with error -192 - so the app bundle is the terminology
       carrier, and this is where the keys live. -->
  <key>NSAppleScriptEnabled</key>      <true/>
  <key>OSAScriptingDefinition</key>    <string>Roast.sdef</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>MojoCocoaSourceRevision</key>   <string>$GITREV</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>      <string>Mojo source</string>
      <key>CFBundleTypeRole</key>      <string>Editor</string>
      <key>LSHandlerRank</key>         <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array><string>org.mojococoa.mojo-source</string></array>
    </dict>
  </array>
  <!-- An exported type, so .mojo is a kind of source code the system knows
       about rather than a claim on every plain text file. Listing
       public.plain-text as the content type -- which this did first -- makes
       Roast a candidate handler for README.txt, which is not the offer we
       want to make. Owner rank because nothing else on the machine defines
       this type. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>      <string>org.mojococoa.mojo-source</string>
      <key>UTTypeDescription</key>     <string>Mojo source</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.source-code</string>
        <string>public.utf8-plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>mojo</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$C/PkgInfo"

# The scripting dictionary, beside the plist that names it.
cp -f "$ROOT/ide/Roast.sdef" "$C/Resources/Roast.sdef"
if sdef "$APP" 2>/dev/null | grep -q 'do command'; then
  echo "   sdef: terminology resolves (do command)"
else
  echo "   FAILED -- sdef(1) cannot read the dictionary from the bundle"
  exit 1
fi

# An icon if one has been drawn; the generic app icon otherwise. Named rather
# than assumed, so adding tools/roast.icns is all it takes.
if [ -f "$ROOT/tools/roast.icns" ]; then
  cp -f "$ROOT/tools/roast.icns" "$C/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
      "$C/Info.plist" >/dev/null
  echo "   icon: tools/roast.icns"
fi

# ── signing ────────────────────────────────────────────────────────────────
# Ad-hoc, and deep: an unsigned bundle on Apple Silicon will not launch at
# all, and every nested Mach-O needs its own signature. This is not
# notarisation -- someone downloading the .dmg still has to allow it once in
# System Settings -- but it is the difference between "asks permission" and
# "is killed on sight".
echo "== signing =="
if codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null; then
  codesign --verify --deep "$APP" 2>/dev/null \
    && echo "   ad-hoc signed and verified" \
    || echo "   WARNING: signed but verification failed"
else
  echo "   WARNING: could not sign -- the app may not launch"
fi

echo
echo "$APP ($(du -sh "$APP" | cut -f1))"

[ "$want_dmg" = 0 ] && exit 0

# ── the disk image ─────────────────────────────────────────────────────────
# A staging folder with the app and a symlink to /Applications, which is the
# drag-here convention every Mac user already knows. UDBZ compresses hardest,
# which matters: the Cocoa database alone is a third of a gigabyte and is
# exactly the sort of thing bzip2 is good at.
echo "== disk image =="
DMG="$OUT/Roast-$VER.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Roast.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<TXT
Roast $VER ($GITREV)

An IDE for cocoa-mojo, written in cocoa-mojo. Drag Roast to Applications.

It carries its own toolchain -- compiler, language server, standard library
and the Cocoa database -- plus CPython for Mojo's in-process Python interop --
so cmd-B builds and cmd-R runs with nothing else installed. The Python menu
creates one environment per project under Application Support and runs pip
inside it. The Examples menu opens the projects it ships with.

First launch: macOS will refuse an app it has not seen before. Right-click
Roast and choose Open, or allow it in System Settings > Privacy & Security.
This build is ad-hoc signed, not notarised.

Requires Apple Silicon and macOS 15 or later.
TXT

rm -f "$DMG"
hdiutil create -quiet -srcfolder "$STAGE" -volname "Roast $VER" \
    -format UDBZ -fs HFS+ "$DMG"
echo "   $DMG ($(du -sh "$DMG" | cut -f1))"
echo
echo "open $DMG"
