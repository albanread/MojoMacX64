#!/usr/bin/env bash
# Our cache of built components, kept where we control the lifetime.
#
# The toolchain is assembled out of a handful of large, independently loadable
# artifacts: the language server, lldb and liblldb, our MojoLLDB plugin, the
# runtime dylibs. They are dynamically linked on purpose -- the layout resolves
# through @rpath with no install_name_tool and no re-signing -- which is
# exactly what makes them cacheable as artifacts. Nothing has to be relinked
# to use one; it only has to be present.
#
# Until now make-dist read them straight out of bazel-out. That works right up
# until bazel garbage-collects its own scratch space, and then a release that
# changes nothing but documentation cannot be cut, because a build system threw
# away a file it was under no obligation to keep. bazel-out is bazel's, and
# bazel may empty it whenever it likes.
#
# So: when a component is built, we keep a copy. When bazel-out has it, that
# wins and the cache is refreshed. When bazel-out does not, the cache answers.
#
# A cached component is never passed off as a fresh one. Every generation
# records the commit it was built from, and restoring one asks git whether the
# source that feeds it has changed since. Unchanged is silent; changed is
# refused, because a debugger plugin built against different compiler
# internals is the stale-artifact failure this whole pipeline exists to
# prevent.

COMPONENTS="${COCOAMOJO_COMPONENTS:-$ROOT/.components}"

_c_dir() { printf '%s/%s' "$COMPONENTS" "$1"; }

# components_store <group> <commit> <src:destsubdir>...
# Copy freshly built files into the cache and make them the latest generation.
components_store() {
  local group="$1" commit="$2"; shift 2
  local dir stamp tmp
  dir="$(_c_dir "$group")"
  mkdir -p "$dir" || return 1

  # Content-addressed, so rebuilding identical bits does not make a second
  # copy and `latest` keeps pointing at the same generation.
  tmp="$(mktemp -d "$dir/.staging.XXXXXX")" || return 1
  : > "$tmp/MANIFEST"
  local spec src destsub
  for spec in "$@"; do
    src="${spec%%:*}"; destsub="${spec##*:}"
    [ -f "$src" ] || { rm -rf "$tmp"; return 1; }
    cp -f "$src" "$tmp/" || { rm -rf "$tmp"; return 1; }
    printf '%s %s\n' "$(basename "$src")" "$destsub" >> "$tmp/MANIFEST"
  done

  stamp="$(cat "$tmp"/* 2>/dev/null | shasum -a 256 | cut -c1-16)"
  if [ -d "$dir/$stamp" ]; then
    rm -rf "$tmp"
  else
    mv "$tmp" "$dir/$stamp" || { rm -rf "$tmp"; return 1; }
    {
      printf 'component %s\n' "$group"
      printf 'commit    %s\n' "$commit"
      printf 'built     %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      printf 'source    %s\n' "${COMPONENT_SOURCE:-bazel-out}"
      printf 'host      %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    } > "$dir/$stamp/PROVENANCE"
  fi
  ln -sfn "$stamp" "$dir/latest"
  return 0
}

components_have() { [ -d "$(_c_dir "$1")/latest" ]; }

components_commit() {
  sed -n 's/^commit *//p' "$(_c_dir "$1")/latest/PROVENANCE" 2>/dev/null
}

components_built() {
  sed -n 's/^built *//p' "$(_c_dir "$1")/latest/PROVENANCE" 2>/dev/null
}

components_source() {
  sed -n 's/^source *//p' "$(_c_dir "$1")/latest/PROVENANCE" 2>/dev/null
}

# components_stale <group> <path>...
# Has anything under <path> changed since the cached generation was built?
# Deliberately broad: over-invalidating costs a rebuild, under-invalidating
# ships a component built against source that no longer exists.
components_stale() {
  local group="$1"; shift
  local commit; commit="$(components_commit "$group")"
  [ -n "$commit" ] || return 0
  git cat-file -e "$commit^{commit}" 2>/dev/null || return 0
  git diff --quiet "$commit" HEAD -- "$@" 2>/dev/null && return 1
  return 0
}

# components_restore <group> <distdir>
components_restore() {
  local group="$1" dist="$2"
  local dir; dir="$(_c_dir "$group")/latest"
  [ -f "$dir/MANIFEST" ] || return 1
  local name destsub
  while read -r name destsub; do
    [ -n "$name" ] || continue
    mkdir -p "$dist/$destsub"
    cp -f "$dir/$name" "$dist/$destsub/" || return 1
  done < "$dir/MANIFEST"
  return 0
}
