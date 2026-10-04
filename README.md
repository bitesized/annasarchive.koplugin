# Anna's Archive for KOReader

A KOReader plugin to search [Anna's Archive](https://annas-archive.org) and
download books directly to your device.

It does not talk to Anna's Archive directly. Instead it talks to a small
self-hosted companion service,
[annas-archive-api](https://github.com/bitesized/annas-archive-api), which
handles scraping search results and proxying authenticated fast-download
requests.

```
KOReader plugin  ──HTTP──▶  annas-archive-api  ──HTTPS──▶  Anna's Archive
```

## Requirements

- KOReader (tested on v2025.10).
- A running instance of
  [annas-archive-api](https://github.com/bitesized/annas-archive-api) reachable
  from your device.
- Your Anna's Archive account secret key. Both searching and downloading need
  it — Anna's Archive puts anonymous searches behind a DDoS-Guard challenge that
  only a signed-in session skips.

## Installation

1. Download the zip from the [latest
   release](https://github.com/bitesized/annasarchive.koplugin/releases/latest)
   and unpack it into KOReader's `plugins/` directory:

   ```
   <koreader>/plugins/annasarchive.koplugin/
   ├── _meta.lua
   └── main.lua
   ```

   On a Kobo this is typically
   `/mnt/onboard/.adds/koreader/plugins/annasarchive.koplugin/`.

   The directory **must** be named `annasarchive.koplugin`: KOReader only
   looks at directories whose name ends in `.koplugin`, and silently ignores
   everything else. The release zip already has the name right. GitHub's own
   "Download ZIP" button does not -- it gives you
   `annasarchive.koplugin-main`, which KOReader will not load until you
   rename it.

2. Restart KOReader. The plugin appears in the menu under **Anna's Archive**.

## Configuration

Open **Anna's Archive → Settings** and set:

| Setting           | Default                      | Description                                                        |
| ----------------- | ---------------------------- | ------------------------------------------------------------------ |
| API Host          | `localhost`                  | Host where `annas-archive-api` is running.                         |
| API Port          | `3000`                       | Port for the API (matches the API's `PORT`).                       |
| Anna's Archive TLD| _(not set)_                  | **Required.** Mirror TLD passed to the API as `tld`, e.g. `gd`. Your key is sent to this mirror — check [Anna's Archive's Wikipedia page](https://en.wikipedia.org/wiki/Anna%27s_Archive) for the current list, as retired mirrors get re-registered. |
| Secret Key        | _(not set)_                  | Your Anna's Archive account secret key. Required to search and download. |
| Sort results      | Relevance                    | Order of the result list: Relevance (Anna's Archive's order), Most downloaded, Title A–Z, Author A–Z, or Format. |
| Download Dir      | `<koreader data>/downloads`  | Where downloaded files are saved.                                  |

The plugin builds requests as `http://<API Host>:<API Port>/api`. Point these at
wherever you are hosting the companion API.

If the API runs on a machine at home and you want to search from elsewhere,
one option is [Tailscale](https://tailscale.com): install it on the API host and
on your e-reader, then set API Host to the host's Tailscale IP or MagicDNS name.
The device reaches the API over your tailnet without exposing it to the
internet.

If you're using a Kobo,
[kobo-tailscale](https://github.com/videah/kobo-tailscale) installs Tailscale on
the device and keeps it running across reboots. It lists the Kobo models it
supports, and its README covers a fix if DNS stops resolving on the device
afterwards. On other devices, you'll need another way to run Tailscale.

## Usage

1. **Anna's Archive → Search Anna's Archive**, type a query, and confirm.
2. Pick a result from the list. Results appear straight away; cover thumbnails
   fill in as they download in the background (and are cached for next time).
   To change the query, tap the search icon at the top left of the results;
   the box opens with your current query, and the old results stay up until
   the new search returns.
3. Confirm the download. The file is fetched and saved to your Download Dir,
   then you'll see the saved path.

Both steps require the secret key and a TLD; the plugin asks you to set them
before it will search. The same key authorises search and download — it's the
one from your Anna's Archive account page.

## How it talks to the API

- **Search** — `GET /api/search?query=<q>&limit=20&tld=<tld>` with an
  `Authorization: Bearer <secret key>` header. Expects a JSON body with a
  `results` array, where each entry has at least `title` and `md5` (and
  optionally `author`, `format`, `downloads`, and `cover_url`).
- **Download** — `GET /api/download?md5=<md5>&tld=<tld>` with the same
  `Authorization: Bearer <secret key>` header. Expects a JSON body with a
  `download_url` (or `url`) field, which the plugin then fetches via `wget`.

Error responses carry `{"error": "...", "code": "..."}`; the plugin surfaces
`error` directly. A `401` (missing key, rejected key, or `code: "CHALLENGE"`
when the upstream served a bot check) is reported with a pointer back to
Settings.

See the
[annas-archive-api README](https://github.com/bitesized/annas-archive-api) for
how to run and configure the service.

## Notes

- The secret key is sent as a `Bearer` token to your API host over plain HTTP,
  so keep that host on a network you trust -- a home LAN, or a tailnet (see
  [Configuration](#configuration)).
- Malformed or partial search entries (which Anna's Archive can emit during
  outages or DDoS-Guard challenges) are dropped defensively, and JSON `null`
  values for optional fields are handled gracefully.
- Downloads use `wget --no-check-certificate`; the device needs `wget`
  available (standard on Kobo/KOReader).

## License

See the repository for license details.
