#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'engine: env.sh is sourced, not run: source engine/scripts/env.sh\n' >&2
  exit 2
fi

ARARAT_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# a chromium-build default is a cwd-relative path once a swept env(1) leaves
# $HOME unset, so the default stays unset and the commands refuse it
# (require_tree, lock_take); --help must survive the same sweep, which is why
# the refusal cannot sit up here
: "${ARARAT_BUILD_ROOT:=${HOME:+$HOME/chromium-build}}"
: "${ARARAT_SRC_DIR:=$ARARAT_BUILD_ROOT/src}"
if [[ -d "$ARARAT_SRC_DIR" ]]; then
  ARARAT_SRC_DIR="$(cd -- "$ARARAT_SRC_DIR" && pwd -P)"
fi
: "${ARARAT_DEPOT_TOOLS:=$ARARAT_BUILD_ROOT/depot_tools}"
: "${ARARAT_ENGINE_LOCK:=$ARARAT_BUILD_ROOT/.engine.lock}"
: "${ARARAT_PATCHES:=$ARARAT_REPO_ROOT/engine/patches}"
: "${ARARAT_SERIES:=$ARARAT_PATCHES/series}"
: "${ARARAT_MANIFEST:=$(dirname -- "$ARARAT_PATCHES")/patch-state.sha256}"
: "${ARARAT_BUILD_INPUTS:=$ARARAT_REPO_ROOT/engine/build-inputs.toml}"
: "${ARARAT_GCLIENT_JOBS:=4}"
export ARARAT_REPO_ROOT ARARAT_BUILD_ROOT ARARAT_SRC_DIR ARARAT_DEPOT_TOOLS \
  ARARAT_ENGINE_LOCK ARARAT_PATCHES ARARAT_SERIES ARARAT_MANIFEST \
  ARARAT_BUILD_INPUTS ARARAT_GCLIENT_JOBS

# The nix devshell's MACOSX_DEPLOYMENT_TARGET/SDKROOT reach Chromium's rustc and
# break host-tool links, so they do not reach the engine build either.
unset MACOSX_DEPLOYMENT_TARGET SDKROOT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEPOT_TOOLS_UPDATE=0
# Nothing from /nix or the caller reaches PATH: nix's xcbuild xcrun cannot find
# the MobileAsset Metal toolchain, and the shebangs below then resolve to
# /bin/bash, the only bash a clean PATH offers
export PATH="$ARARAT_DEPOT_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

TMPDIR="${TMPDIR:-/tmp}"; TMPDIR="${TMPDIR%/}"

msg() { printf 'engine: %s\n' "$*"; }
die() { printf 'engine: %s\n' "$*" >&2; exit 1; }

toml_get() {
  awk -F'=' -v key="$1" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    { k = $1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k) }
    k == key {
      v = $2
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      sub(/^"/, "", v)
      sub(/"[[:space:]]*$/, "", v)
      print v; exit
    }' "$ARARAT_BUILD_INPUTS" 2>/dev/null
}

series_lines() { awk 'NF && $1 !~ /^#/' "$ARARAT_SERIES"; }

series_fingerprint() {
  {
    cat -- "$ARARAT_SERIES"
    series_lines | while IFS= read -r rel; do
      if [[ -f "$ARARAT_PATCHES/$rel" ]]; then
        cat -- "$ARARAT_PATCHES/$rel"
      else
        printf 'missing patch %s\n' "$rel"
      fi
    done
  } | shasum -a 256 | awk '{print $1}'
}

manifest_data_lines() {
  awk 'NF && $1 != "series" && $1 !~ /^#/' "$ARARAT_MANIFEST" 2>/dev/null
  # the manifest may legitimately not exist yet (first apply); an empty read
  # then says "nothing recorded", not an error
}

# git apply strips exactly one leading path component (-p1 covers all a/ b/
# diffs); still, decide per patch so a quilt-style -p0 diff would not be
# silently mangled.
patch_strip() {
  local s
  s="$(awk '
    /^--- / {
      p = $2
      if (p == "/dev/null") next
      if (substr(p, 1, 2) == "a/" || substr(p, 1, 2) == "b/") { print 1; exit }
      { print 0; exit }
    }' "$1")"
  case "$s" in 0|1) echo "$s" ;; *) echo 1 ;; esac
}

touched_paths() {
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    awk '
      /^(\+\+\+|---) / {
        p = $2
        if (p == "/dev/null") next
        if (substr(p, 1, 2) == "a/" || substr(p, 1, 2) == "b/") p = substr(p, 3)
        sub(/[[:space:]]+$/, "", p)
        print p
      }' "$ARARAT_PATCHES/$rel"
  done < <(series_lines) | LC_ALL=C sort -u
}

repo_of() {
  local probe root sub
  probe="$ARARAT_SRC_DIR/$(dirname -- "$1")"
  while [[ ! -e "$probe" && "$probe" != "$ARARAT_SRC_DIR" ]]; do
    probe="$(dirname -- "$probe")"
  done
  if ! root="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null)"; then
    root="$ARARAT_SRC_DIR"
  fi
  root="$(cd -- "$root" && pwd -P)"
  printf '%s\n' "$root"
}

touched_repos() {
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    repo_of "$rel"
  done < <(touched_paths) | LC_ALL=C sort -u
}

# The layer pairs as engine directory and src-tree destination.
layer_pairs() {
  printf '%s\t%s\n' engine/ararat ararat/core
  if [[ -d "$ARARAT_REPO_ROOT/engine/chrome" ]]; then
    printf '%s\t%s\n' engine/chrome chrome/browser/ararat
  fi
}

# The layer directories as their src-tree paths, the engine directory being
# the source of truth, so a file deleted from it leaves the manifest too.
# -type f keeps symlinks out of the manifest; copy_layer refuses them, so the
# copy and the manifest stay consistent.
layer_paths() {
  local src dst
  {
    while IFS=$'\t' read -r src dst; do
      (cd "$ARARAT_REPO_ROOT/$src" && find . -type f | sed "s|^\\./|$dst/|")
    done < <(layer_pairs)
  } | LC_ALL=C sort -u
}

# The files actually under the copied layer directories, src-tree relative:
# the complement against layer_paths is a stray the manifest never sees.
layer_strays() {
  local src dst
  {
    while IFS=$'\t' read -r src dst; do
      [[ -d "$ARARAT_SRC_DIR/$dst" ]] || continue
      (cd "$ARARAT_SRC_DIR/$dst" && find . -type f | sed "s|^\\./|$dst/|")
    done < <(layer_pairs)
  } | LC_ALL=C sort -u
}

# The stamp gen writes into the args.gn it produces and build rechecks: the
# built Chromium version and the manifest hash, so the value moves with the
# series, the patches and the layer together.
engine_version_value() {
  local version hash
  [[ -r "$ARARAT_MANIFEST" ]] || die "no manifest ($ARARAT_MANIFEST): run apply"
  [[ -r "$ARARAT_SRC_DIR/chrome/VERSION" ]] || die "no Chromium VERSION: $ARARAT_SRC_DIR/chrome/VERSION"
  version="$(awk -F= 'NF == 2 { printf "%s%s", sep, $2; sep = "." }' "$ARARAT_SRC_DIR/chrome/VERSION")"
  hash="$(shasum -a 256 -- "$ARARAT_MANIFEST" | awk '{print substr($1, 1, 12)}')"
  printf '%s (ararat %s)' "$version" "$hash"
}

# rsync, not cp: --delete drops a layer file removed from the engine directory
# and --checksum leaves the mtimes of files whose bytes did not change, so
# ninja does not recompile them; why -t is not kept — a file restored with an
# old mtime would arrive with new bytes ninja would not rebuild. Symlinks are
# refused: rsync -l would copy one that the manifest (-type f) never sees.
# The exported names must match in the two places they are listed: ararat.exports
# (the linker's -exported_symbols_list) and the "# Ararat" block the link patch
# appends to chrome/app/framework.order (verify_order.py refuses any export the
# order file does not list). Both sides parse comments and blanks away, and the
# comparison is by set: a name in one file only fails apply and series-check.
check_layer_exports() {
  local exports="$ARARAT_REPO_ROOT/engine/ararat/ararat.exports"
  local patch="$ARARAT_PATCHES/ararat/link-ararat-layer.patch"
  local a b only_a only_b
  [[ -r "$exports" ]] || die "no layer exports file: $exports"
  [[ -r "$patch" ]] || die "no link patch: $patch"
  a="$(awk '{ line = $0; sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line); if (line != "") print line }' "$exports" | LC_ALL=C sort -u)"
  b="$(awk '
    /^\+\+\+ / { infw = ($2 ~ /framework\.order$/); next }
    !infw { next }
    /^\+# Ararat/ { inblock = 1; next }
    inblock && !/^\+/ { inblock = 0; next }
    inblock {
      line = substr($0, 2)
      sub(/#.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      if (line != "") print line
    }
  ' "$patch" | LC_ALL=C sort -u)"
  only_a="$(comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed '/^$/d')"
  only_b="$(comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed '/^$/d')"
  if [[ -n "$only_a" || -n "$only_b" ]]; then
    die "ararat.exports and the link patch's framework.order block disagree (only in ararat.exports: $(printf '%s' "$only_a" | tr '\n' ' '); only in the order block: $(printf '%s' "$only_b" | tr '\n' ' ')): list every exported name in both"
  fi
  # Every export must be defined in the layer: a text match on the C name without
  # the leading underscore, an @implementation for ObjC class names. Why not nm:
  # there is no build output at apply time.
  local name def
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      _OBJC_CLASS_\$_*|_OBJC_METACLASS_\$_*)
        def="${name#_OBJC_CLASS_\$_}"; def="${def%_}"
        grep -rq --include="*.mm" --include="*.cc" -- "@implementation $def" "$ARARAT_REPO_ROOT/engine/ararat" \
          || die "ararat.exports names $name but engine/ararat has no @implementation $def" ;;
      *)
        def="${name#_}"
        grep -rq --include="*.mm" --include="*.cc" -- "$def" "$ARARAT_REPO_ROOT/engine/ararat" \
          || die "ararat.exports names $name but engine/ararat defines no $def" ;;
    esac
  done <<<"$a"
}

copy_layer() {
  local src dst link
  while IFS=$'\t' read -r src dst; do
    link="$(cd "$ARARAT_REPO_ROOT/$src" && find . -type l | head -n1)" || return 1
    if [[ -n "$link" ]]; then
      die "symlinks are not supported in the layer: $ARARAT_REPO_ROOT/$src/${link#./}"
    fi
  done < <(layer_pairs)
  while IFS=$'\t' read -r src dst; do
    rsync -rl --delete --checksum "$ARARAT_REPO_ROOT/$src/" "$ARARAT_SRC_DIR/$dst/"
  done < <(layer_pairs)
}

_engine_lock_owned=0
_signal_child=
_engine_scratch=

_engine_exit_all() {
  _engine_release_lock
  if [[ -n "$_engine_scratch" ]]; then
    rm -rf -- "$_engine_scratch"
    _engine_scratch=
  fi
}

_engine_release_lock() {
  [[ "$_engine_lock_owned" == 1 ]] || return 0
  _engine_lock_owned=0
  rm -rf -- "$ARARAT_ENGINE_LOCK"
}

_engine_signal_exit() {
  local rc=130
  [[ "$1" == TERM ]] && rc=143
  trap '' INT TERM
  if [[ -n "$_signal_child" ]]; then
    # the child has its own process group, so the TERM reaches its children
    # too, and it is waited out to keep the lock release behind their death
    kill -TERM -- "-$_signal_child" 2>/dev/null
    wait "$_signal_child" 2>/dev/null || true
  fi
  _engine_release_lock
  exit "$rc"
}

# mkdir(2) is atomic and is the only lock primitive macOS ships;
# a kill -9 leaves the directory behind without a writer to clean it up.
_engine_lock_acquired() {
  _engine_lock_owned=1
  printf '%s\n' "$$" >"$ARARAT_ENGINE_LOCK/pid"
  trap '_engine_signal_exit INT' INT
  trap '_engine_signal_exit TERM' TERM
  trap '_engine_exit_all' EXIT
}

lock_take() {
  local attempt pid judged now stale reclaim
  [[ -n "$ARARAT_BUILD_ROOT" ]] || die "set HOME or ARARAT_BUILD_ROOT"
  [[ -d "$ARARAT_BUILD_ROOT" ]] || die "no build root directory for the lock: $ARARAT_BUILD_ROOT"
  for attempt in 1 2; do
    mkdir -- "$ARARAT_ENGINE_LOCK" 2>/dev/null && { _engine_lock_acquired; return 0; }
    # give a creator that has the directory but not yet its pid a moment to finish
    sleep 0.2
  done
  reclaim="$ARARAT_ENGINE_LOCK.reclaim"
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    if [[ $attempt -gt 250 ]]; then
      die "cannot take the engine lock (still judging after 50s): after checking that no engine command is running, clear \"$ARARAT_ENGINE_LOCK\" and \"$reclaim\" (if present) with rmdir"
    fi
    if [[ ! -d "$ARARAT_ENGINE_LOCK" ]]; then
      # a reclaim window holds the directory aside; judge again once it returns
      sleep 0.2
      continue
    fi
    judged="$(cat -- "$ARARAT_ENGINE_LOCK/pid" 2>/dev/null || true)"
    if [[ -z "$judged" ]]; then
      # the directory is there but no pid: a creator or a returning window has
      # not written it yet, so one grace round before the hand-clear recipe
      if [[ ${_engine_pidless_seen:-0} == 1 ]]; then
        die "the engine lock holds no readable pid: after checking that no engine command is running, clear it with: rmdir \"$ARARAT_ENGINE_LOCK\""
      fi
      _engine_pidless_seen=1
      sleep 0.2
      continue
    fi
    if kill -0 -- "$judged" 2>/dev/null; then
      die "another engine command holds the lock (pid $judged): $ARARAT_ENGINE_LOCK"
    fi
    # The reclaim is serialised through a sibling directory: two takers can
    # judge the same dead holder, and between one's mv and its mkdir another
    # can re-create the lock whose directory that one's restore-mv would
    # otherwise nest into (mv onto an existing directory moves into it). The
    # window holds the fresh read and the mv, a lock re-made outside it is
    # left to the next judging round, and mv never targets the lock path.
    if ! mkdir -- "$reclaim" 2>/dev/null; then
      _engine_pidless_seen=0
      sleep 0.2
      continue
    fi
    now="$(cat -- "$ARARAT_ENGINE_LOCK/pid" 2>/dev/null || true)"
    if [[ -z "$now" ]]; then
      # same creator grace as above, this time inside the window
      sleep 0.2
      now="$(cat -- "$ARARAT_ENGINE_LOCK/pid" 2>/dev/null || true)"
    fi
    if [[ -z "$now" ]]; then
      rmdir -- "$reclaim"
      die "the engine lock holds no readable pid: after checking that no engine command is running, clear it with: rmdir \"$ARARAT_ENGINE_LOCK\""
    fi
    if kill -0 -- "$now" 2>/dev/null; then
      rmdir -- "$reclaim"
      die "another engine command holds the lock (pid $now): $ARARAT_ENGINE_LOCK"
    fi
    judged="$now"
    _engine_pidless_seen=0
    stale="$ARARAT_ENGINE_LOCK.stale.$$.$RANDOM"
    if [[ -d "$stale" ]]; then
      # a leftover of a dead taker whose pid this process shares after a recycle
      rm -rf -- "$stale"
    fi
    if mv -- "$ARARAT_ENGINE_LOCK" "$stale" 2>/dev/null; then
      if [[ "$(cat -- "$stale/pid" 2>/dev/null || true)" == "$judged" ]]; then
        rm -rf -- "$stale"
        if mkdir -- "$ARARAT_ENGINE_LOCK" 2>/dev/null; then
          rmdir -- "$reclaim"
          _engine_lock_acquired
          return 0
        fi
        # a fresh creation won the gap between the mv and this mkdir; its pid
        # shows up shortly and the next judging round decides on it
      else
        # not the judged directory (cannot happen with the window held): the
        # moved one stays parked under this taker's stale name, and the next
        # round judges the directory the lock path now holds
        :
      fi
    fi
    rmdir -- "$reclaim"
    sleep 0.2
  done
}
lock_release() { _engine_release_lock; }

require_tree() {
  # an unset build root is the swept-env(1) case, see the default above;
  # refusing here and in lock_take keeps --help working with no HOME
  [[ -n "$ARARAT_BUILD_ROOT" ]] || die "set HOME or ARARAT_BUILD_ROOT"
  [[ -d "$ARARAT_SRC_DIR/.git" ]] || die "not a git checkout: $ARARAT_SRC_DIR"
  [[ -r "$ARARAT_SERIES" ]] || die "no series file: $ARARAT_SERIES"
}

# git apply is transactional only within one file, and once any file of any of
# its hunks is written there is no undo short of a reset, so the failure paths
# here always end in reset_tree.
reset_tree() {
  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if [[ ! -d "$r" ]]; then
      die "repository not checked out, run fetch first: $r"
    fi
    git -C "$r" reset -q --hard
    # /out anchors the exemption at the repository root, where the src
    # checkout keeps its build products; /ararat/ and /chrome/browser/ararat/
    # exempt the copied layer, which the copy step maintains — why the layer is
    # not cleaned: a cleaned copy would be recreated with fresh mtimes and push
    # ninja into recompiling unchanged files
    git -C "$r" clean -qfd -e /out -e /ararat/ -e /chrome/browser/ararat/
  done < <({
    touched_repos
    if [[ -r "$ARARAT_MANIFEST" ]]; then
      manifest_repo_map | LC_ALL=C cut -f1
    fi
  } | LC_ALL=C sort -u)
}

apply_series() {
  local rel f strip err rc file
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    f="$ARARAT_PATCHES/$rel"
    if [[ ! -f "$f" ]]; then
      msg "FAILED before any patch: missing file $rel"
      reset_tree
      die "apply: missing patch file $rel; tree reset"
    fi
    strip="$(patch_strip "$f")"
    err="$(git -C "$ARARAT_SRC_DIR" apply "-p$strip" --whitespace=nowarn -- "$f" 2>&1)" && {
      msg "+ $rel"
      continue
    }
    rc=$?
    file="$(printf '%s\n' "$err" | grep -m1 -oE 'patch failed: [^:]+' | cut -d' ' -f3- || true)"
    printf '%s\n' "$err" | sed 's/^/        /'
    msg "FAILED $rel (exit $rc)${file:+, file: $file}"
    reset_tree
    die "apply: stopped at the first failing patch; tree reset"
  done < <(series_lines)
}

manifest_actual() {
  local rel f h
  {
    printf 'series %s\n' "$(series_fingerprint)"
    while IFS= read -r rel; do
      f="$ARARAT_SRC_DIR/$rel"
      if [[ -e "$f" ]]; then
        h="$(shasum -a 256 -- "$f" | awk '{print $1}')"
        printf '%s  %s\n' "$h" "$rel"
      else
        printf -- '-  %s\n' "$rel"
      fi
    done < <({ touched_paths; layer_paths; })
  }
}

manifest_record() {
  local tmp="$ARARAT_MANIFEST.tmp" n
  mkdir -p -- "$(dirname -- "$ARARAT_MANIFEST")" || return 1
  manifest_actual >"$tmp" || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  if [[ -r "$ARARAT_MANIFEST" ]] && cmp -s -- "$tmp" "$ARARAT_MANIFEST"; then
    rm -f -- "$tmp"
    return 0
  fi
  # minus the series line; bash 3.2 rejects a quoted operand inside $(( ))
  n="$(wc -l <"$tmp" | tr -d ' ')" || { rm -f -- "$tmp"; return 1; }
  n=$((n - 1))
  mv -- "$tmp" "$ARARAT_MANIFEST" || { rm -f -- "$tmp"; return 1; }
  msg "manifest recorded: $ARARAT_MANIFEST ($n files)"
}

manifest_check() {
  [[ -r "$ARARAT_MANIFEST" ]] \
    || die "no manifest to compare with ($ARARAT_MANIFEST): run apply first"
  local rec cur out rc=0 n
  rec="$(awk '$1 == "series" { print $2; exit }' "$ARARAT_MANIFEST")"
  cur="$(series_fingerprint)"
  if [[ -z "$rec" || "$rec" != "$cur" ]]; then
    die "the manifest was recorded for a different series: run apply"
  fi
  out="$(diff -u -- "$ARARAT_MANIFEST" <(manifest_actual))" || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" | sed 's/^/        /'
    die "the series does not reproduce the recorded bytes ('-' recorded, '+' tree): run apply"
  fi
  local strays
  strays="$(comm -13 <(layer_paths) <(layer_strays))"
  if [[ -n "$strays" ]]; then
    printf '%s\n' "$strays" | sed 's/^/        /'
    die "files in the copied layer are not the engine's: run apply"
  fi
  n="$(wc -l <"$ARARAT_MANIFEST" | tr -d ' ')"
  n=$((n - 1))
  msg "the series reproduces the recorded bytes ($n files)"
}

manifest_repo_map() {
  local sha rel root sub
  while read -r sha rel; do
    [[ -n "$rel" ]] || continue
    root="$(repo_of "$rel")"
    sub=""
    case "$root" in
      "$ARARAT_SRC_DIR") sub="" ;;
      "$ARARAT_SRC_DIR"/*) sub="${root#"$ARARAT_SRC_DIR"/}" ;;
    esac
    if [[ -n "$sub" && "$rel" == "$sub/"* ]]; then
      printf '%s\t%s\n' "$root" "${rel#"$sub"/}"
    else
      printf '%s\t%s\n' "$root" "$rel"
    fi
  done < <(manifest_data_lines)
}

apply_would_write_nothing() {
  local map="$1" exp="$2" r
  cmp -s -- "$ARARAT_MANIFEST" <(manifest_actual) || return 1
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    awk -F'\t' -v r="$r" '$1 == r { print $2 }' "$map" | LC_ALL=C sort >"$exp"
    # a nested repository the map checks on its own also reaches the parent's
    # status, as an untracked dir line or as a gitlink line, and whether git
    # prints that line at all depends on the parent's diff.ignoreSubmodules;
    # the line is the nested repo's own judging instead, whose entry below
    # keeps the idle path off git config
    awk -F'\t' -v base="$r/" \
      'index($1, base) == 1 { print substr($1, length(base) + 1) }' \
      "$map" | LC_ALL=C sort -u >"$exp.skip"
    git -C "$r" status --porcelain -uall | awk \
      -v expfile="$exp" -v skipfile="$exp.skip" \
      -v srcroot="$ARARAT_SRC_DIR" -v root="$r" '
      function unq(p,    out, i, n, c, nxt) {
        # porcelain wraps odd characters in C-style quotes while the manifest
        # carries raw bytes, so the wrap comes off before any comparison;
        # the two path-visible escapes decode in one left-to-right pass,
        # a gsub chain would mis-order a backslash next to a quote escape
        if (p !~ /^".*"$/) return p
        p = substr(p, 2, length(p) - 2)
        out = ""
        n = length(p)
        for (i = 1; i <= n; i++) {
          c = substr(p, i, 1)
          if (c == "\\" && i < n) {
            nxt = substr(p, i + 1, 1)
            if (nxt == "\\" || nxt == "\"") {
              out = out nxt
              i++
              continue
            }
          }
          out = out c
        }
        return out
      }
      BEGIN {
        while ((getline line < expfile) > 0) expect[line] = 1
        close(expfile)
        while ((getline line < skipfile) > 0) nested[line] = 1
        close(skipfile)
      }
      {
        mark = substr($0, 1, 2)
        path = substr($0, 4)
        sub(/[ \t\r]+$/, "", path)
        path = unq(path)
        # apply only ever produces modified, added or deleted touched paths;
        # anything else in the worktree is drift the reset path has to clear
        if (mark !~ /^( M| D|\?\?)$/) exit 1
        # reset keeps out/ for the src checkout only, so the no-write path
        # does not count it as drift either
        if (root == srcroot && path ~ /^out\//) next
        # the map carries no trailing slash on its roots, the untracked dir
        # line does; without the strip the skip lookup below always misses
        np = path
        sub(/\/$/, "", np)
        if (np in nested) next
        if (!(path in expect)) exit 1
      }
    ' || return 1
  done < <(LC_ALL=C cut -f1 -- "$map" | LC_ALL=C sort -u)
  # The manifest hashes the copied bytes, not the engine-side sources, so an
  # edited engine/ararat file leaves the comparison above green; only the
  # dry-run rsync sees it. Why not copy_layer before the check: the copy would
  # write src on an apply that must stay read-only and push a layer-only change
  # through the full reset path.
  local lsrc ldst itemize
  while IFS=$'\t' read -r lsrc ldst; do
    itemize="$(rsync -rl --delete --checksum --dry-run --itemize-changes \
      "$ARARAT_REPO_ROOT/$lsrc/" "$ARARAT_SRC_DIR/$ldst/" 2>&1)"
    if [[ -n "$itemize" ]]; then return 1; fi
  done < <(layer_pairs)
}


