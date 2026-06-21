#!/usr/bin/env bash
# Adds redmine-docker-workspace bin/ to the current shell PATH.
# Usage:
#   source /path/to/activate-workspace-tool.sh
#
# Works in two contexts:
#   - From the tool repository: bin/ is located next to this script
#   - From a workspace:         tool path is read from .rdc_state

_rdc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$_rdc_script_dir/bin/redmine-docker-workspace" ]]; then
  _rdc_bin_dir="$_rdc_script_dir/bin"
else
  _rdc_state="$_rdc_script_dir/.rdc_state"
  if [[ -f "$_rdc_state" ]]; then
    _rdc_bin_dir=$(grep "^tool_bin_dir=" "$_rdc_state" 2>/dev/null | cut -d= -f2-)
  fi
fi

if [[ -n "${_rdc_bin_dir:-}" ]]; then
  if [[ ":$PATH:" != *":${_rdc_bin_dir}:"* ]]; then
    export PATH="${_rdc_bin_dir}:$PATH"
  fi
else
  echo "ERROR: activate-workspace-tool.sh: cannot determine tool location." >&2
fi

unset _rdc_bin_dir _rdc_state _rdc_script_dir
