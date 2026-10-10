#!/usr/bin/env bash
# Keyword post search, via the raw passthrough against LinkedIn's search-results page.
#
# This is currently the ONLY path proven to return real keyword-matched posts.
# `POST /v1/search/posts` does NOT work -- it calls voyager/api/search/dash/clusters,
# which LinkedIn no longer serves content results from. See
# worker/app/adapters/search_posts.py for the full measured findings.
#
# Yield is a handful of posts per request (the page renders only the first few;
# the rest load on scroll via an SDUI pagination call that is not wired up yet).
#
# Usage:  ./test-search.sh "your keyword"  [account_id]
set -euo pipefail

KEYWORD="${1:-ai automation}"
ACCOUNT="${2:-acc_6d840e4cd4084e68a1dc316d}"
WORKER="${WORKER_URL:-http://127.0.0.1:8001}"   # matches worker/.env INTERNAL_PORT
# cd into the script dir and use relative paths: Git Bash reports POSIX paths
# (/c/...) which native Windows Python resolves as C:\c\... and cannot open.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Read the token from .env by absolute path -- a relative path only works from
# the project root, and an empty token surfaces as a confusing
# `{"detail":"bad internal token"}` rather than as "you are in the wrong directory".
TOKEN="$(sed -n 's/^INTERNAL_TOKEN=//p' worker/.env | tr -d '\r\n')"
if [ -z "$TOKEN" ]; then
  echo "could not read INTERNAL_TOKEN from worker/.env" >&2
  exit 1
fi

ENC="$(python -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$KEYWORD")"
URL="https://www.linkedin.com/search/results/content/?keywords=${ENC}&origin=FACETED_SEARCH"

echo "keyword: $KEYWORD"
echo "url    : $URL"

# The body is built by python rather than inline, so quoting the URL and the
# keyword cannot break the JSON.
python - "$ACCOUNT" "$URL" <<'PYEOF' > .search-req.json
import json, sys
print(json.dumps({
    "account_id": sys.argv[1],
    "op_class": "READ",
    "method": "GET",
    "request_url": sys.argv[2],
    "headers": {"accept": "text/html,application/xhtml+xml"},
}))
PYEOF

curl -s -X POST "$WORKER/internal/linkedin/raw" \
  -H "content-type: application/json" \
  -H "x-internal-token: $TOKEN" \
  --data @.search-req.json \
| python tools/parse-search.py
