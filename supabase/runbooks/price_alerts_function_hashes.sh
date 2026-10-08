#!/usr/bin/env bash
# 85Blends 2.4.1 — Price Alerts: SOURCE-HASH VALIDATION of the two Edge Functions. Local and read-only: it reads files from this
# repository (the working tree, or any git revision) and, optionally, from a directory of sources you downloaded from the deployed
# functions; it never talks to Supabase, Apple or Google and writes nothing.
#
# Why it exists. The deployed functions are replaced as a whole. Two things must be true, and both are comparisons of file
# bytes: (1) BEFORE the deploy, what is running in production is exactly the revision we think it is (nobody edited it in the
# dashboard; no other branch was deployed); (2) AFTER the deploy, what is running is exactly the revision we meant to ship.
# Supabase's own bundle hash (in PRICE_ALERTS_RECOVERY.md) is a hash of the packed bundle and cannot be reproduced from files,
# so this script compares the SOURCE FILES one by one.
#
# Usage:
#   price_alerts_function_hashes.sh                       print sha256 of every deployable file in the working tree
#   price_alerts_function_hashes.sh --rev <git-rev>       the same, for a git revision (default: the working tree)
#   price_alerts_function_hashes.sh [--rev <rev>] --against <dir>
#                                                         compare with downloaded sources: <dir>/price-alerts-api/*.ts etc.
#                                                         Exit 0 only if every file matches and the deployed copy has no extra file.
#
# How to get <dir> (read-only; needs the owner's authorization and a Supabase login):
#   supabase functions download price-alerts-api    --project-ref <ref> --use-api     (then the same for price-alerts-worker)
# or the equivalent read of the function's files in the dashboard / MCP get_edge_function. Put each function's files under
# <dir>/<function-name>/ . A "deno.json" the platform adds is compared like any other file.
#
# BEFORE a deploy:  --rev <the revision the previous deploy came from> --against <downloaded>   => must be all MATCH
# AFTER  a deploy:  (working tree or the shipped revision) --against <downloaded again>          => must be all MATCH
set -euo pipefail

REV=""
AGAINST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rev) REV="${2:?--rev needs a git revision}"; shift 2 ;;
    --against) AGAINST="${2:?--against needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# The files each function is deployed from: its entry point and every module it imports (tests and notes are not deployed).
declare -A FILES=(
  [price-alerts-api]="index.ts alert-input.ts values.ts deno.json"
  [price-alerts-worker]="index.ts auth.ts fcm.ts message.ts deno.json"
)
ORDER=(price-alerts-api price-alerts-worker)

read_file() { # <function> <file>  -> bytes on stdout, nonzero if absent in the chosen revision
  if [ -n "$REV" ]; then git -C "$REPO" show "$REV:supabase/functions/$1/$2" 2>/dev/null
  else cat "$REPO/supabase/functions/$1/$2" 2>/dev/null; fi
}
sha() { sha256sum | cut -d' ' -f1; }

echo "# source: ${REV:-working tree of $REPO}"
status=0
for fn in "${ORDER[@]}"; do
  for f in ${FILES[$fn]}; do
    if ! mine="$(read_file "$fn" "$f" | sha; exit "${PIPESTATUS[0]}")"; then
      # a file the chosen revision does not have (the previous version had fewer files): say so, and do not count it as a mismatch
      echo "absent     $fn/$f   (not part of ${REV:-the working tree})"
      if [ -n "$AGAINST" ] && [ -f "$AGAINST/$fn/$f" ]; then echo "EXTRA      $fn/$f   (present in the deployed copy)"; status=1; fi
      continue
    fi
    if [ -z "$AGAINST" ]; then
      echo "$mine  $fn/$f"
    elif [ ! -f "$AGAINST/$fn/$f" ]; then
      echo "MISSING    $fn/$f   (not in the deployed copy)"; status=1
    else
      theirs="$(sha256sum < "$AGAINST/$fn/$f" | cut -d' ' -f1)"
      if [ "$mine" = "$theirs" ]; then echo "MATCH      $fn/$f   $mine"; else echo "DIFFER     $fn/$f   repo $mine  deployed $theirs"; status=1; fi
    fi
  done
  if [ -n "$AGAINST" ] && [ -d "$AGAINST/$fn" ]; then
    for path in "$AGAINST/$fn"/*; do
      [ -f "$path" ] || continue
      name="$(basename "$path")"
      case " ${FILES[$fn]} " in *" $name "*) ;; *) echo "EXTRA      $fn/$name   (in the deployed copy, not deployed from this repository)"; status=1 ;; esac
    done
  fi
done
if [ -n "$AGAINST" ]; then
  if [ "$status" -eq 0 ]; then echo "RESULT: every file matches"; else echo "RESULT: MISMATCH - do not proceed until it is explained"; fi
fi
exit "$status"
