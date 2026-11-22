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
| API host          | `localhost`                  | Host where `annas-archive-api` is running. A pasted URL is trimmed to the host, and a `:port` on the end is saved as the port. |
| API port          | `3000`                       | Port for the API (matches the API's `PORT`). Must be 1–65535.      |
| Anna's Archive TLD| _(not set)_                  | **Required.** Mirror TLD passed to the API as `tld`, e.g. `gd`. Your key is sent to this mirror — check [Anna's Archive's Wikipedia page](https://en.wikipedia.org/wiki/Anna%27s_Archive) for the current list, as retired mirrors get re-registered. |
| Secret key        | _(not set)_                  | Your Anna's Archive account secret key. Required to search and download. |
| Test connection   | —                            | Checks the API is reachable (`/api/health`) and whether it can reach Anna's Archive. |
| Sort results      | Relevance                    | Order of the result list: Relevance (Anna's Archive's order), Most downloaded, Title A–Z, Author A–Z, or Format. |
| Filter results    | Any                          | Only show the chosen formats (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ, TXT) and/or one language code, e.g. `en`. Filtering happens on the device, since the API has no filter parameters. |
| Download folder   | `<koreader data>/downloads`  | Where downloaded files are saved by default. Choosing a folder with **Save to…** when downloading remembers it for that format. |
| Clear cover cache | —                            | Shows how much space cached cover thumbnails use, and deletes them. |

The plugin builds requests as `http://<API Host>:<API Port>/api`. Point these at
wherever you are hosting the companion API.

If the API runs on a machine at home and you want to search from elsewhere,
one option is [Tailscale](https://tailscale.com): install it on the API host and
on your e-reader, then set API Host to the host's Tailscale IP or MagicDNS name.
The device reaches the API over your tailnet without exposing it to the
internet.

[koreader-tailscale](https://github.com/victoria-riley-barnett/koreader-tailscale) lets you use
Tailscale within KOReader. Its README covers how to use it and any
device-specific considerations.

## Usage

1. **Anna's Archive → Search Anna's Archive**, type a query, and confirm. The
   **History** button lists your last 10 searches.
2. Pick a result from the list. Results appear straight away; cover thumbnails
   fill in as they download in the background (and are cached for next time).
   The cover cache is capped at 20 MB: before each search, the covers shown
   least recently are deleted to bring it back under.
   To change the query, tap the search icon at the top left of the results;
   the box opens with your current query, and the old results stay up until
   the new search returns.
   Each row shows the format, size, year, language and download count where
   Anna's Archive has them. **Load more** at the bottom fetches the next page.
3. Confirm the download. Tap **Save to…** to pick a different folder; that
   folder becomes the default for books of the same format. The download runs
   in the background with a progress dialog you can cancel. The file is written
   as a `.part` and only renamed once complete, and an existing file with the
   same name is never overwritten: ` (2)`, ` (3)`… is added instead.
4. When it finishes, **Open now** opens the book straight away.

Both steps require the secret key and a TLD; the plugin asks you to set them
before it will search. The same key authorises search and download — it's the
one from your Anna's Archive account page.

## How it talks to the API

- **Search** — `GET /api/search?query=<q>&limit=50&page=<n>&tld=<tld>` with an
  `Authorization: Bearer <secret key>` header. Expects a JSON body with a
  `results` array, where each entry has at least `title` and `md5` (and
  optionally `author`, `format`, `year`, `language`, `size`, `downloads`, and
  `cover_url`). The API trims each upstream page to `limit`, so the plugin asks
  for the maximum of 50 to make sure **Load more** doesn't skip results.
- **Download** — `GET /api/download?md5=<md5>&tld=<tld>` with the same
  `Authorization: Bearer <secret key>` header. Expects a JSON body with a
  `download_url` (or `url`) field, which must be an `http(s)` URL. The plugin
  then fetches it with a backgrounded `wget`.
- **Test connection** — `GET /api/health?upstream=1`, no key needed.

Error responses carry `{"error": "...", "code": "..."}`; the plugin surfaces
`error` directly, with a hint for the common cases: a `401` (missing key,
`BAD_KEY`, or `CHALLENGE` when the upstream served a bot check) and a `400`
`UNKNOWN_MIRROR` point back to Settings, and a `429` says how long to wait
(from `Retry-After`). API requests time out after 90 seconds.

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
- Filenames are built from the title (up to 80 characters) and author (up to
  40), with characters that are illegal on FAT/exFAT replaced. A result with
  an unknown or unusual format is saved as `.bin`.

## License

See the repository for license details.
