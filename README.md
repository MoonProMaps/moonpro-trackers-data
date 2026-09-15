# moonpro-trackers-data

The public records behind [Moon Trackers](https://moonpro.io/moon-trackers): insider trades, congressional
stock trades, committee seats, hearings, bills, federal contracts, campaign totals, FDA approvals,
clinical trials, Federal Reserve releases, short-sale volume and Wikipedia attention.

Written only by the [Publish trackers](.github/workflows/publish.yml) workflow, every two hours. It runs
the open-source [LuxAlgo Market Trackers](https://github.com/LuxAlgo/market-trackers) pipeline against the
primary sources and commits the export here, in the same layout as `LuxAlgo/market-trackers-data`.
MoonPro isn't affiliated with LuxAlgo.

- `manifest.json` — row counts and when each dataset last took new rows.
- `<dataset>/YYYY/YYYY-MM-DD.json` — rows ingested that day; `latest.json` is the newest.
- `<dataset>/snapshot.json.gz` — the whole dataset, where the site reads it that way.

## Running it

- **Secret:** `SEC_CONTACT_EMAIL` — the SEC requires a contact email on EDGAR requests.
- **Catch up after an outage:** Actions → Publish trackers → Run workflow, with `since` set to the
  first missing day.
- **Locally:** build `LuxAlgo/market-trackers`, then
  `PIPELINE_DIR=… STORE=store.db OUT_DIR=dumps SEED_DIR=<a dumps checkout> MARKET_TRACKERS_CONTACT=… bash scripts/publish.sh`.

## License

The data is public-domain government records, dedicated to the public domain under [CC0 1.0](LICENSE).
Every row carries a `provenance.sourceUrl` back to its primary document.
