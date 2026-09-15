#!/usr/bin/env bash
# Sync MoonPro's trackers from the primary sources and export them in the
# market-trackers-data layout moonpro.io reads (lib/trackers/source.ts).
#
# The same script runs in the scheduled GitHub Action and on a laptop, so a
# local run is a real test of the published pipeline.
#
# Env:
#   PIPELINE_DIR             built checkout of LuxAlgo/market-trackers
#   STORE                    SQLite store carried between runs
#   OUT_DIR                  where the export is written (replaced each run)
#   MARKET_TRACKERS_CONTACT  contact email the SEC requires in EDGAR requests
#   SEED_DIR                 a dumps checkout to rebuild STORE from when it's missing
#   SINCE                    optional YYYY-MM-DD to re-walk from
set -euo pipefail

: "${PIPELINE_DIR:?set PIPELINE_DIR}" "${STORE:?set STORE}" "${OUT_DIR:?set OUT_DIR}"
: "${MARKET_TRACKERS_CONTACT:?set MARKET_TRACKERS_CONTACT (SEC EDGAR requires a contact email)}"

cli() { node "$PIPELINE_DIR/packages/cli/dist/index.js" "$@"; }

# Only what moonpro.io shows. Patents, PAC contributions, lobbying, 13F and
# COT are left out on purpose — too large to serve live, or empty.
DATASETS="insider-transactions,congress-trades,committee-assignments,congress-hearings,bills,gov-contracts,fec-candidates,fda-approvals,clinical-trials,fed-communications,short-volume,wiki-pageviews"
# Most important first: when a run is short on time, the sources at the end
# are the ones that wait for the next run. EDGAR (insider trades) leads.
SOURCES="edgar senate-efd house-clerk federalreserve openfda finra wikimedia congress-legislators fec clinicaltrials govinfo-hearings usaspending govinfo"

# Time budgets, in minutes. One source may take SOURCE_BUDGET before it is
# stopped (its rows so far are kept; it resumes next run), and no new source
# starts once SYNC_BUDGET is spent — so export and commit always get to run.
SOURCE_BUDGET="${SOURCE_BUDGET:-25}"
SYNC_BUDGET="${SYNC_BUDGET:-65}"
# directory:dataset — a single dataset directory has to be told which dataset it holds.
DIRS="insider/transactions:insider-transactions congress/trades:congress-trades congress/committees:committee-assignments congress/hearings:congress-hearings congress/bills:bills contracts/awards:gov-contracts fec/candidates:fec-candidates fda/approvals:fda-approvals clinical-trials/studies:clinical-trials fed/communications:fed-communications short-volume/daily:short-volume wiki/pageviews:wiki-pageviews"

if [ ! -f "$STORE" ]; then
  : "${SEED_DIR:?no store to resume from — set SEED_DIR to a dumps checkout to rebuild it}"
  echo "::group::Rebuild store from $SEED_DIR"
  for pair in $DIRS; do
    dir="${pair%%:*}"
    id="${pair##*:}"
    if [ -d "$SEED_DIR/$dir" ]; then cli import "$SEED_DIR/$dir" --dataset "$id" --db "$STORE" --log warn; fi
  done
  echo "::endgroup::"
  # Dumps don't carry the sync watermarks, so a rebuilt store would only look
  # back a few days. Re-walk from just before the seed's oldest "last ingested".
  if [ -z "${SINCE:-}" ] && [ -f "$SEED_DIR/manifest.json" ]; then
    SINCE=$(node -e '
      const m = require(process.argv[1]); const ids = process.argv[2].split(",");
      const days = ids.map((id) => m.datasets?.[id]?.lastIngestedAt).filter(Boolean).map((d) => Date.parse(d));
      if (days.length) console.log(new Date(Math.min(...days) - 3 * 864e5).toISOString().slice(0, 10));
    ' "$(cd "$SEED_DIR" && pwd)/manifest.json" "$DATASETS")
  fi
fi

SINCE_ARGS=()
if [ -n "${SINCE:-}" ]; then SINCE_ARGS=(--since "$SINCE"); echo "Re-walking from $SINCE"; fi

# One source at a time, each on its own clock. A first catch-up over two weeks
# took longer than a whole run allows when every source went in one call, and
# a job stopped by the platform exported nothing at all.
started=$(date +%s)
for source in $SOURCES; do
  spent=$(( ($(date +%s) - started) / 60 ))
  if [ "$spent" -ge "$SYNC_BUDGET" ]; then
    echo "Sync budget spent (${spent}m) — $source waits for the next run."
    continue
  fi
  echo "::group::Sync $source (${spent}m in)"
  if timeout --signal=INT --kill-after=60 "${SOURCE_BUDGET}m" \
    node "$PIPELINE_DIR/packages/cli/dist/index.js" sync --db "$STORE" --source "$source" \
      --dataset "$DATASETS" --json "${SINCE_ARGS[@]}" > "sync-$source.json"; then
    echo "$source: ok"
  else
    # Rows written before the stop are committed; the source picks up from its
    # watermark next run. A failure here never blocks the other sources.
    echo "::warning::$source did not finish (exit $?) — it continues next run."
  fi
  echo "::endgroup::"
done

echo "::group::Export"
rm -rf "$OUT_DIR"
cli export --db "$STORE" --dataset "$DATASETS" --out "$OUT_DIR" --log warn
echo "::endgroup::"

# Trim what the site never reads, so the repo doesn't grow with files nobody fetches:
# per-entity RSS, year shards (the site reads snapshot.json.gz), and the full
# snapshots of the three datasets the site reads as daily files instead.
find "$OUT_DIR" -type d -name feeds -prune -exec rm -rf {} +
find "$OUT_DIR" -name 'feed.xml' -delete
find "$OUT_DIR" -name 'snapshot-*.json.gz' -delete
rm -f "$OUT_DIR/insider/transactions/snapshot.json.gz" "$OUT_DIR/short-volume/daily/snapshot.json.gz" "$OUT_DIR/congress/bills/snapshot.json.gz"

node -e '
  const m = require(process.argv[1]);
  for (const [id, d] of Object.entries(m.datasets)) console.log(id.padEnd(24), String(d.rows).padStart(8), d.lastIngestedAt ?? "-");
' "$(cd "$OUT_DIR" && pwd)/manifest.json"
