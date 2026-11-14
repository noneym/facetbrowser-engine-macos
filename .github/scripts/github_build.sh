#!/bin/bash -eux

# Simple partitioned (2 of 3) build script for building Ungoogled-Chromium macOS binaries on GitHub Actions
# Resuming build script for macOS

_target_cpu="${1:-x86_64}"

_root_dir="$(dirname "$(greadlink -f "$0")")"
_src_dir="$_root_dir/build/src"

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
      xargs ninja -C out/Default -k 0 < "$_root_dir/facet_preflight_targets.txt"
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

timeout -k 7m -s SIGTERM "${_remaining_time}s" ninja -C out/Default chrome chromedriver

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
