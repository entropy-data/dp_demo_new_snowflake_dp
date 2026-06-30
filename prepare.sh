#!/usr/bin/env bash
# Publish the shelf-warmer-clearance-optimizer demo to the Entropy Data platform
# using the entropy-data CLI:
#
#   1. the output data contract (ODCS)  -> datacontracts put
#   2. the data product (ODPS)          -> dataproducts put
#
# The contract is published first because the data product's output port
# references it; publishing the product against a missing contract would dangle.
#
# Usage:
#   ./prepare.sh            # publish both
#   ./prepare.sh --dry-run  # show what would happen, change nothing
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# --- identity (kept in sync with the data product / contract) ----------------
DATA_PRODUCT_ID="shelf-warmer-clearance-optimizer"
DATA_CONTRACT_ID="clearance-recommendations-v1"
ODPS_FILE="clearance-optimizer.odps.yaml"
ODCS_FILE="datacontracts/clearance_recommendations_v1.odcs.yaml"

# --- args --------------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)  DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

run() { # run a mutating command, honoring --dry-run
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# Resolve a CLI ("$1") preferring a global binary, else `uv run` inside a venv.
resolve_cli() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "$1"
  elif [[ -f pyproject.toml ]] && command -v uv >/dev/null 2>&1; then
    echo "uv run --quiet $1"
  else
    echo ""
  fi
}

ED="$(resolve_cli entropy-data)"
if [[ -z "$ED" ]]; then
  echo "entropy-data CLI not available — install it or activate the venv first." >&2
  exit 1
fi
if [[ $DRY_RUN -eq 0 ]] && ! $ED connection test >/dev/null 2>&1; then
  echo "entropy-data not connected — run 'entropy-data connection add' first." >&2
  exit 1
fi

# ============================================================================
echo "==> 1/2  Publish data contract (ODCS) ${DATA_CONTRACT_ID}"
if [[ ! -f "$ODCS_FILE" ]]; then
  echo "    Missing ${ODCS_FILE}" >&2; exit 1
fi
run $ED datacontracts put "$DATA_CONTRACT_ID" --file "$ODCS_FILE"

# ============================================================================
echo
echo "==> 2/2  Publish data product (ODPS) ${DATA_PRODUCT_ID}"
if [[ ! -f "$ODPS_FILE" ]]; then
  echo "    Missing ${ODPS_FILE}" >&2; exit 1
fi
run $ED dataproducts put "$DATA_PRODUCT_ID" --file "$ODPS_FILE"

echo
echo "Publish complete."
