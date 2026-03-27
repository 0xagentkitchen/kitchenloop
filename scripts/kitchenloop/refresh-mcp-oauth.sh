#!/bin/bash
# Refresh MCP OAuth tokens stored in macOS Keychain
#
# Claude Code stores MCP OAuth tokens (e.g., Linear) in macOS Keychain under
# "Claude Code-credentials". When running claude in headless mode (--print),
# expired OAuth tokens can't be refreshed via browser redirect. This script
# performs a programmatic token refresh using the OAuth refresh_token grant.
#
# Usage:
#   ./scripts/kitchenloop/refresh-mcp-oauth.sh           # Refresh all MCP tokens
#   ./scripts/kitchenloop/refresh-mcp-oauth.sh --check    # Check expiry only, no refresh
#   ./scripts/kitchenloop/refresh-mcp-oauth.sh --force    # Force refresh even if not expired
#
# Returns 0 on success, 1 if any token could not be refreshed.

set -euo pipefail

MODE="auto"   # auto | check | force
BUFFER_SECS=3600  # Refresh if expiring within 1 hour

while [[ $# -gt 0 ]]; do
  case $1 in
    --check) MODE="check"; shift ;;
    --force) MODE="force"; shift ;;
    --buffer)
      BUFFER_SECS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="${USER}"

# ─── Read credentials from Keychain ──────────────────────────────────────
read_credentials() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null
}

# ─── Write credentials back to Keychain ──────────────────────────────────
write_credentials() {
  local creds="$1"
  # Delete + re-add (security doesn't support in-place update)
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
  security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$creds" 2>/dev/null
}

# ─── Main ────────────────────────────────────────────────────────────────
CREDS_JSON=$(read_credentials)
if [ -z "$CREDS_JSON" ]; then
  echo "ERROR: No Claude Code credentials found in Keychain"
  exit 1
fi

# Extract all mcpOAuth entries
MCP_KEYS=$(echo "$CREDS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
mcp = d.get('mcpOAuth', {})
for key in mcp:
    print(key)
" 2>/dev/null)

if [ -z "$MCP_KEYS" ]; then
  echo "No MCP OAuth entries found in credentials"
  exit 0
fi

NOW_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
REFRESHED=0
FAILED=0

for mcp_key in $MCP_KEYS; do
  # Extract token details
  TOKEN_INFO=$(echo "$CREDS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
entry = d['mcpOAuth']['$mcp_key']
print(json.dumps({
    'serverName': entry.get('serverName', ''),
    'serverUrl': entry.get('serverUrl', ''),
    'accessToken': entry.get('accessToken', ''),
    'refreshToken': entry.get('refreshToken', ''),
    'expiresAt': entry.get('expiresAt', 0),
    'clientId': entry.get('clientId', ''),
    'scope': entry.get('scope', ''),
    'discoveryState': entry.get('discoveryState', {}),
}))
" 2>/dev/null)

  SERVER_NAME=$(echo "$TOKEN_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['serverName'])")
  EXPIRES_AT=$(echo "$TOKEN_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['expiresAt'])")
  REFRESH_TOKEN=$(echo "$TOKEN_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['refreshToken'])")
  CLIENT_ID=$(echo "$TOKEN_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['clientId'])")
  TOKEN_ENDPOINT=$(echo "$TOKEN_INFO" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ds = d.get('discoveryState', {})
meta = ds.get('authorizationServerMetadata', {})
print(meta.get('token_endpoint', ''))
" 2>/dev/null)

  if [ -z "$REFRESH_TOKEN" ] || [ -z "$TOKEN_ENDPOINT" ] || [ -z "$CLIENT_ID" ]; then
    echo "  [$SERVER_NAME] SKIP - missing refresh_token, token_endpoint, or client_id"
    continue
  fi

  # Check expiry
  REMAINING_MS=$(( EXPIRES_AT - NOW_MS ))
  REMAINING_SECS=$(( REMAINING_MS / 1000 ))
  REMAINING_HOURS=$(( REMAINING_SECS / 3600 ))
  REMAINING_DAYS=$(( REMAINING_HOURS / 24 ))

  if [ "$REMAINING_SECS" -gt 0 ]; then
    STATUS="valid (${REMAINING_DAYS}d ${REMAINING_HOURS}h remaining)"
  else
    STATUS="EXPIRED ($(( -REMAINING_SECS / 3600 ))h ago)"
  fi

  echo "  [$SERVER_NAME] Token $STATUS"

  # Decide whether to refresh
  SHOULD_REFRESH=false
  if [ "$MODE" = "force" ]; then
    SHOULD_REFRESH=true
  elif [ "$MODE" = "check" ]; then
    SHOULD_REFRESH=false
  elif [ "$REMAINING_SECS" -lt "$BUFFER_SECS" ]; then
    SHOULD_REFRESH=true
    echo "  [$SERVER_NAME] Token expires within buffer (${BUFFER_SECS}s), refreshing..."
  fi

  if [ "$SHOULD_REFRESH" = false ]; then
    continue
  fi

  # Perform token refresh
  echo "  [$SERVER_NAME] Refreshing via $TOKEN_ENDPOINT ..."
  RESPONSE=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=$CLIENT_ID" \
    -d "refresh_token=$REFRESH_TOKEN" 2>&1)

  # Check for error
  ERROR=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        print(d.get('error_description', d['error']))
    elif 'access_token' not in d:
        print('No access_token in response')
    else:
        print('')
except Exception as e:
    print(f'Invalid response: {e}')
" 2>/dev/null)

  if [ -n "$ERROR" ]; then
    echo "  [$SERVER_NAME] FAILED to refresh: $ERROR"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Parse new tokens
  NEW_ACCESS_TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
  NEW_REFRESH_TOKEN=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('refresh_token', ''))")
  EXPIRES_IN=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('expires_in', 604800))")

  NEW_EXPIRES_AT=$(python3 -c "import time; print(int(time.time() * 1000 + $EXPIRES_IN * 1000))")

  # Update credentials JSON
  CREDS_JSON=$(echo "$CREDS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
entry = d['mcpOAuth']['$mcp_key']
entry['accessToken'] = '$NEW_ACCESS_TOKEN'
entry['expiresAt'] = $NEW_EXPIRES_AT
refresh = '$NEW_REFRESH_TOKEN'
if refresh:
    entry['refreshToken'] = refresh
print(json.dumps(d, separators=(',', ':')))
" 2>/dev/null)

  NEW_REMAINING_DAYS=$(( EXPIRES_IN / 86400 ))
  echo "  [$SERVER_NAME] OK - new token valid for ${NEW_REMAINING_DAYS} days"
  REFRESHED=$((REFRESHED + 1))
done

# Write back if any tokens were refreshed
if [ "$REFRESHED" -gt 0 ]; then
  write_credentials "$CREDS_JSON"
  echo ""
  echo "Refreshed $REFRESHED MCP OAuth token(s), written to Keychain"
fi

if [ "$FAILED" -gt 0 ]; then
  echo "WARNING: $FAILED token(s) failed to refresh"
  exit 1
fi

exit 0
