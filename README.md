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
- An Anna's Archive fast-download key (for downloads; searching works without
  one).

## Installation

1. Copy this folder into KOReader's `plugins/` directory, keeping the
   `annasarchive.koplugin` folder name:

   ```
   <koreader>/plugins/annasarchive.koplugin/
   ├── _meta.lua
   └── main.lua
   ```

   On a Kobo this is typically
   `/mnt/onboard/.adds/koreader/plugins/annasarchive.koplugin/`.

2. Restart KOReader. The plugin appears in the menu under **Anna's Archive**.

## Configuration

Open **Anna's Archive → Settings** and set:

| Setting           | Default                      | Description                                                        |
| ----------------- | ---------------------------- | ------------------------------------------------------------------ |
| API Host          | `localhost`                  | Host where `annas-archive-api` is running.                         |
| API Port          | `3000`                       | Port for the API (matches the API's `PORT`).                       |
| Anna's Archive TLD| `gs`                         | TLD passed through to the API as the `tld` query parameter.        |
| Download Key      | _(not set)_                  | Your Anna's Archive fast-download key. Required for downloads.     |
| Download Dir      | `<koreader data>/downloads`  | Where downloaded files are saved.                                  |

The plugin builds requests as `http://<API Host>:<API Port>/api`. Point these at
wherever you are hosting the companion API.

## Usage

1. **Anna's Archive → Search**, type a query, and confirm.
2. Pick a result from the list (the format is shown on the right).
3. Confirm the download. The file is fetched and saved to your Download Dir,
   then you'll see the saved path.

Searching does not require a download key; downloading does.

## How it talks to the API

- **Search** — `GET /api/search?query=<q>&limit=20&tld=<tld>`
  Expects a JSON body with a `results` array, where each entry has at least
  `title` and `md5` (and optionally `author` and `format`).
- **Download** — `GET /api/download?md5=<md5>&tld=<tld>` with an
  `Authorization: Bearer <download key>` header. Expects a JSON body with a
  `download_url` (or `url`) field, which the plugin then fetches via `wget`.

See the
[annas-archive-api README](https://github.com/bitesized/annas-archive-api) for
how to run and configure the service.

## Notes

- Malformed or partial search entries (which Anna's Archive can emit during
  outages or DDoS-Guard challenges) are dropped defensively, and JSON `null`
  values for optional fields are handled gracefully.
- Downloads use `wget --no-check-certificate`; the device needs `wget`
  available (standard on Kobo/KOReader).

## License

See the repository for license details.
