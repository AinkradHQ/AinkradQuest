#!/usr/bin/env bash
# Quest's generated Citadel client (Packages/QuestCitadelAPI): only the operations listed in
# contract/openapi-generator-config.yaml. Same script as AinkradCitadelPlugin's; keep the two in step. Two modes:
#
#   scripts/contract.sh regen [<citadel-rev>]   copy api/openapi.json from the Citadel repo at <citadel-rev>
#                                               (default: the pinned contract/CITADEL_REVISION), pin it, and
#                                               regenerate Sources/QuestCitadelAPI/Generated
#   scripts/contract.sh check                   the committed client matches the pinned spec, and the pinned spec
#                                               matches the Citadel repo's development (when that repo is present)
#
# GENERATOR: a swift-openapi-generator 1.14.2 binary (git clone -b 1.14.2
#   https://github.com/apple/swift-openapi-generator && swift build -c release). The generator drops a property it
#   cannot express with only a warning, so any warning fails the run.
# CITADEL_REPO: the server checkout (default ../AinkradCitadel next to this repo).
set -euo pipefail
cd "$(dirname "$0")/.."
pkg=Packages/QuestCitadelAPI
citadel="${CITADEL_REPO:-../AinkradCitadel}"

generate() {  # <spec> <out-dir>
  local log
  log=$(mktemp)
  mkdir -p "$2"
  if ! "${GENERATOR:?set GENERATOR to a swift-openapi-generator 1.14.2 binary}" generate \
    --config "$pkg/contract/openapi-generator-config.yaml" --output-directory "$2" "$1" >"$log" 2>&1 \
    || grep -qi "warning\|error" "$log"; then
    cat "$log" >&2
    echo "contract: the generator was not clean" >&2
    exit 1
  fi
}

case "${1:-}" in
regen)
  rev="${2:-$(cat "$pkg/contract/CITADEL_REVISION")}"
  rev=$(git -C "$citadel" rev-parse --verify "$rev^{commit}")
  git -C "$citadel" show "$rev:api/openapi.json" >"$pkg/contract/openapi.json"
  echo "$rev" >"$pkg/contract/CITADEL_REVISION"
  generate "$pkg/contract/openapi.json" "$pkg/Sources/QuestCitadelAPI/Generated"
  echo "contract: regenerated from Citadel $rev"
  ;;
check)
  status=0
  if [ -n "${GENERATOR:-}" ]; then
    out=$(mktemp -d)
    generate "$pkg/contract/openapi.json" "$out"
    diff -r "$out" "$pkg/Sources/QuestCitadelAPI/Generated" >/dev/null \
      || { echo "contract: the committed client is stale — run make contract" >&2; status=1; }
  else
    echo "contract: GENERATOR not set — the committed client was NOT re-generated"
  fi
  if git -C "$citadel" rev-parse --verify -q origin/development >/dev/null 2>&1; then
    if git -C "$citadel" show origin/development:api/openapi.json | cmp -s - "$pkg/contract/openapi.json"; then
      echo "contract: pinned spec matches Citadel origin/development"
    else
      echo "contract: Citadel origin/development has a newer spec than the pin ($(cat "$pkg/contract/CITADEL_REVISION"))" >&2
      echo "          run: make contract REV=origin/development" >&2
      status=1
    fi
  else
    echo "contract: no Citadel checkout at $citadel — spec drift NOT checked"
  fi
  exit $status
  ;;
*) echo "usage: scripts/contract.sh regen [<citadel-rev>] | check" >&2; exit 2 ;;
esac
