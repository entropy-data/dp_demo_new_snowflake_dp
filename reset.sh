#!/usr/bin/env bash
# Reset the shelf-warmer-clearance-optimizer demo back to its initial state:
# a directory containing only this reset script, the ODPS, and the output-port
# ODCS. Everything the `dataproduct-implement` skill generates — the dbt
# project, the Snowflake database, the platform stamp, the access agreements,
# the local dbt profile, and this project's Claude Code memory — is removed.
#
# What is KEPT (the committed, pristine starting point):
#   - reset.sh
#   - clearance-optimizer.odps.yaml                         (the ODPS)
#   - datacontracts/clearance_recommendations_v1.odcs.yaml  (the output ODCS)
#   - .git / .claude
#
# What is REMOVED:
#   local : dbt_project.yml, pyproject.toml, uv.lock, README.md, .gitignore,
#           openlineage.yml, profiles.yml.example, macros/, models/, analyses/,
#           seeds/, snapshots/, tests/, .github/, target/, logs/, .venv/,
#           dbt_packages/ — and the implement-renamed ODPS is restored to its
#           initial name.
#   cloud : Snowflake database DP_CLEARANCE_OPTIMIZER (dropped)
#   platform : the `dataProductBuilder` customProperty (initial ODPS re-published)
#              and every access agreement of this consumer data product
#   profile  : the `shelf_warmer_clearance_optimizer` dbt profile in ~/.dbt/profiles.yml
#   memory   : ~/.claude/projects/<this-repo-slug>/
#
# Usage:
#   ./reset.sh            # prompts before each destructive step
#   ./reset.sh --yes      # no prompts
#   ./reset.sh --dry-run  # show what would happen, change nothing
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# --- identity (kept in sync with the data product / contract) ----------------
DATA_PRODUCT_ID="shelf-warmer-clearance-optimizer"
DATABASE="DP_CLEARANCE_OPTIMIZER"
ODPS_FILE="clearance-optimizer.odps.yaml"
IMPLEMENT_ODPS_FILE="shelf-warmer-clearance-optimizer.odps.yaml"
ODCS_FILE="datacontracts/clearance_recommendations_v1.odcs.yaml"
DBT_PROFILE="shelf_warmer_clearance_optimizer"
CREDS_PROFILE_FALLBACK="dp_shelf_warmers"

# --- args --------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)      ASSUME_YES=1 ;;
    --dry-run|-n)  DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

confirm() { # confirm "<prompt>"  -> returns 0 to proceed, 1 to skip
  # --yes proceeds unprompted; --dry-run proceeds too (run() guards mutations)
  # so the full set of would-be actions is shown.
  { [[ $ASSUME_YES -eq 1 ]] || [[ $DRY_RUN -eq 1 ]]; } && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

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

# ============================================================================
echo "==> 1/5  Drop Snowflake database ${DATABASE}"
# Credentials from the implement profile, falling back to the shelf-warmers
# profile (same demo account / role). while-read keeps macOS bash 3.2 happy.
read -r ACCOUNT SF_USER SF_PASSWORD SF_ROLE SF_WAREHOUSE < <(
  python3 - "$DBT_PROFILE" "$CREDS_PROFILE_FALLBACK" <<'PY'
import sys, pathlib, yaml
primary, fallback = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(pathlib.Path.home().joinpath(".dbt", "profiles.yml").read_text()) or {}
prof = cfg.get(primary) or cfg.get(fallback)
if not prof:
    print("", "", "", "", ""); sys.exit(0)
o = prof["outputs"][prof.get("target", "dev")]
print(o["account"], o["user"], o["password"], o["role"], o["warehouse"])
PY
)

if [[ -z "${ACCOUNT}" ]]; then
  echo "    No '${DBT_PROFILE}' or '${CREDS_PROFILE_FALLBACK}' dbt profile found — skipping database drop."
elif confirm "    Drop database ${DATABASE} on ${ACCOUNT} (role ${SF_ROLE})?"; then
  run snow sql --temporary-connection \
    --account "$ACCOUNT" --user "$SF_USER" --password "$SF_PASSWORD" \
    --role "$SF_ROLE" --warehouse "$SF_WAREHOUSE" \
    --query "DROP DATABASE IF EXISTS ${DATABASE};"
  echo "    Dropped ${DATABASE}."
else
  echo "    Skipped database drop."
fi

# ============================================================================
echo
echo "==> 2/5  Revert platform state (un-stamp data product, remove access agreements)"
ED="$(resolve_cli entropy-data)"
if [[ -z "$ED" ]]; then
  echo "    entropy-data CLI not available — skipping platform revert."
elif ! $ED connection test >/dev/null 2>&1; then
  echo "    entropy-data not connected — skipping platform revert."
else
  # Un-stamp: re-publish the clean initial ODPS (no dataProductBuilder property).
  # The local ODPS is clean whether or not the implement skill renamed it, so
  # use whichever name is present on disk.
  ODPS_PRESENT="$ODPS_FILE"
  [[ -f "$ODPS_PRESENT" ]] || ODPS_PRESENT="$IMPLEMENT_ODPS_FILE"
  if [[ -f "$ODPS_PRESENT" ]]; then
    if confirm "    Re-publish initial ODPS to drop the dataProductBuilder stamp?"; then
      run $ED dataproducts put "$DATA_PRODUCT_ID" --file "$ODPS_PRESENT"
    fi
  fi
  # Remove every access agreement belonging to this consumer data product.
  ids=()
  while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(
    $ED access list --consumer-dataproduct "$DATA_PRODUCT_ID" -o json 2>/dev/null \
      | jq -r '.[].id' 2>/dev/null || true
  )
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "    No access agreements to remove."
  elif confirm "    Delete ${#ids[@]} access agreement(s) for ${DATA_PRODUCT_ID}?"; then
    for id in "${ids[@]}"; do
      echo "    Deleting access agreement $id"
      run $ED access delete "$id"
    done
  else
    echo "    Skipped access-agreement removal."
  fi
fi

# ============================================================================
echo
echo "==> 3/5  Remove generated local files"
# Restore the ODPS to its initial name if the implement skill renamed it.
if [[ -f "$IMPLEMENT_ODPS_FILE" && ! -f "$ODPS_FILE" ]]; then
  echo "    Restoring ${ODPS_FILE} (from ${IMPLEMENT_ODPS_FILE})"
  run mv "$IMPLEMENT_ODPS_FILE" "$ODPS_FILE"
fi

# Everything not in this allow-list is removed.
KEEP=( "reset.sh" "$ODPS_FILE" "datacontracts" ".git" ".claude" "." ".." )
for entry in $(ls -A); do
  keep=0
  for k in "${KEEP[@]}"; do [[ "$entry" == "$k" ]] && keep=1 && break; done
  if [[ $keep -eq 1 ]]; then continue; fi
  echo "    Removing $entry"
  run rm -rf -- "$entry"
done

# ============================================================================
echo
echo "==> 4/5  Remove the '${DBT_PROFILE}' dbt profile from ~/.dbt/profiles.yml"
PROFILES="$HOME/.dbt/profiles.yml"
if [[ -f "$PROFILES" ]] && python3 -c "import sys,yaml,pathlib; sys.exit(0 if '$DBT_PROFILE' in (yaml.safe_load(pathlib.Path('$PROFILES').read_text()) or {}) else 1)"; then
  if confirm "    Remove profile '${DBT_PROFILE}'?"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] remove key '${DBT_PROFILE}' from $PROFILES"
    else
      python3 - "$PROFILES" "$DBT_PROFILE" <<'PY'
import sys, pathlib, yaml
path, key = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = yaml.safe_load(path.read_text()) or {}
cfg.pop(key, None)
path.write_text(yaml.safe_dump(cfg, sort_keys=False))
PY
      echo "    Removed profile '${DBT_PROFILE}'."
    fi
  else
    echo "    Skipped profile removal."
  fi
else
  echo "    Profile '${DBT_PROFILE}' not present — nothing to remove."
fi

# ============================================================================
echo
echo "==> 5/5  Delete this project's Claude Code memory directory"
PROJECT_SLUG="$(printf '%s' "$DIR" | tr '/_' '--')"
MEMORY_DIR="$HOME/.claude/projects/$PROJECT_SLUG"
if [[ ! -d "$MEMORY_DIR" ]]; then
  echo "    No memory directory at $MEMORY_DIR (nothing to remove)."
elif confirm "    Remove $MEMORY_DIR?"; then
  run rm -rf "$MEMORY_DIR"
  echo "    Removed $MEMORY_DIR."
else
  echo "    Skipped."
fi

echo
echo "Reset complete. Remaining demo files:"
ls -A
