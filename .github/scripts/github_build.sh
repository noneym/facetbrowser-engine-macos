#!/bin/bash -eux

# Simple partitioned (2 of 3) build script for building Ungoogled-Chromium macOS binaries on GitHub Actions
# Resuming build script for macOS

_target_cpu="${1:-x86_64}"

_root_dir="$(dirname "$(greadlink -f "$0")")"
_src_dir="$_root_dir/build/src"

# Compilers run at once. ninja's own default on the 3 core runner is 5, which
# does not fit in its 7 GB of memory once the large Blink files are reached.
_ninja_jobs="${FACET_NINJA_JOBS:-3}"

# GitHub's hard time limit is 6 h per job, we want to spare 1 h for steps before and after the build,
# To get the remaining time for building we subtract 360*60s - 60*60s - (epoch_now - epoch_job_start)
remaining_time() {
  if [[ -f "$_root_dir/epoch_job_start.txt" ]]; then
    echo $(( 360*60 - 60*60 - $(date +%s) + $(cat "$_root_dir/epoch_job_start.txt") ))
  else
    echo 19680 # 328 m
  fi
}

cd "$_src_dir"

echo $(date +%s) | tee -a "$_root_dir/build_times_$_target_cpu.log"
echo "status=running" >> $GITHUB_OUTPUT

# Memory report every ten minutes, printed when this script ends and kept with
# the other logs. It writes to a file so that it never holds the output of
# this step open.
_memory_log="$_root_dir/facet_memory_$_target_cpu.log"
(
  set +ex
  while sleep 600; do
    echo "$(date -u '+%d %H:%M') swap: $(sysctl -n vm.swapusage) | $(memory_pressure | tail -n 1) | largest: $(ps -axo rss=,comm= | sort -rn | head -n 3 | awk '{printf "%d MB %s; ", $1/1024, $NF}')"
  done
) >> "$_memory_log" 2>&1 &
_memory_pid="$!"
trap 'kill "$_memory_pid" 2> /dev/null || true; echo "Memory during this stage:"; tail -n 40 "$_memory_log" || true' EXIT

# Hotfixes: a patch in hotfix/ of this repository is applied once to a tree
# that is already partly built, so that a late compile error can be fixed in a
# run that continues from another one instead of starting over.
for _hotfix in "$_root_dir"/hotfix/*.patch; do
  if [[ ! -f "$_hotfix" ]]; then
    continue
  fi
  _hotfix_marker="out/Default/facet_hotfix_$(basename "$_hotfix").done"
  if [[ ! -f "$_hotfix_marker" ]]; then
    echo "Hotfix: applying $(basename "$_hotfix")"
    patch -p1 --forward --batch --no-backup-if-mismatch -i "$_hotfix"
    touch "$_hotfix_marker"
  fi
done

# Preflight: compile the files changed by the FacetBrowser Engine patches
# before anything else, all of them (-k 0), so that a compile error in a
# ported patch shows up in the first stage instead of days into the build.
# Nothing is built twice: the objects are part of the normal build.
_preflight_marker="out/Default/facet_preflight.done"
if [[ ! -f "$_preflight_marker" ]]; then
  if ninja -C out/Default -t inputs chrome > "$_root_dir/facet_preflight_inputs.txt"; then
    python3 "$_root_dir/facet_preflight.py" "$_root_dir/ungoogled-chromium/patches" \
      "$_root_dir/facet_preflight_inputs.txt" > "$_root_dir/facet_preflight_targets.txt"
    echo "Preflight: compiling $(wc -l < "$_root_dir/facet_preflight_targets.txt" | tr -d ' ') patched files first"

    set +e
    timeout -k 7m -s SIGTERM "$(remaining_time)s" \
      xargs ninja -C out/Default -j "$_ninja_jobs" -k 0 < "$_root_dir/facet_preflight_targets.txt"
    _error_code="${?}"
    set -e

    if [[ "$_error_code" -eq 124 ]]; then
      exit 0
    fi
    if [[ "$_error_code" -ne 0 ]]; then
      echo "Preflight: patched files do not compile"
      exit "$_error_code"
    fi
    cp "$_root_dir/facet_preflight_targets.txt" "$_preflight_marker"
    echo "Preflight: all patched files compile"
  else
    echo "Preflight: skipped, could not list the inputs of chrome"
  fi
  rm -f "$_root_dir/facet_preflight_inputs.txt" "$_root_dir/facet_preflight_targets.txt"
fi

# `timeout 0` would mean no limit at all
_remaining_time="$(remaining_time)"
if [[ "$_remaining_time" -lt 60 ]]; then
  exit 0
fi

set +e

timeout -k 7m -s SIGTERM "${_remaining_time}s" ninja -C out/Default -j "$_ninja_jobs" chrome chromedriver

_error_code="${?}"
if [[ "$_error_code" -eq 124 ]]; then
    exit 0
fi

if [[ "$_error_code" -ne 0 ]]; then
    exit "$_error_code"
fi

set -e

echo $(date +%s) | tee "$_root_dir/build_finished_$_target_cpu.log"
echo "status=finished" >> $GITHUB_OUTPUT
