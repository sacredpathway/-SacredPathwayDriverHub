# Force-Update Runbook

How to force every Sacred Pathway Driver Hub user onto the latest build.

## How it works

On launch, the app fetches a JSON file from a fixed URL and decides whether to show a full-screen blocking "Update App" screen.

- Hard floor: if installed version `<` `minimumSupportedVersion` → blocked.
- Soft kill-switch: if `forceUpdateRequired = true` and installed `<` `latestVersion` → blocked.
- Anything else → allowed in.
- **Network failure → allowed in.** (Fail-open. Carriers never get locked out by a CDN outage.)

Code:
- `Services/ForceUpdateService.swift`
- `Views/ForceUpdateView.swift`
- `Models/RemoteAppConfig.swift`
- URL constant: `Config.ForceUpdate.configURL`

## Hosting

The JSON lives in the **Supabase public bucket `config`** in project `rmzqxsfhjqrshhdjzhze`.

Public URL (hardcoded in `Config.ForceUpdate.configURL`):
```
https://rmzqxsfhjqrshhdjzhze.supabase.co/storage/v1/object/public/config/force-update.json
```

To edit: Supabase Dashboard → Storage → `config` bucket → click `force-update.json` → re-upload (or use the inline editor). The URL stays the same.

**Never change the bucket name or path** — older clients have the URL hardcoded.

## Checklist — flipping the kill-switch

- [ ] Submit new build to App Store and verify it's "Ready for Sale"
- [ ] Edit `force-update.json`:
  - [ ] Set `latestVersion` to the new marketing version (e.g. `1.1.0`)
  - [ ] Set `forceUpdateRequired` to `true`
  - [ ] Update `updateMessage` (what users will read on the blocking screen)
  - [ ] If this version contains a critical bug fix, ALSO bump `minimumSupportedVersion` to the new version — that hard-floors anyone older
- [ ] Re-upload to Squarespace (or your host). Overwrite the existing file.
- [ ] Hit the URL in a private browser tab and confirm the JSON is current.
- [ ] Within ~`Config.ForceUpdate.requestTimeout` of next launch, all out-of-date clients show the blocking screen.

## To unblock (rollback)

- [ ] Edit `force-update.json`
- [ ] Set `forceUpdateRequired` back to `false`
- [ ] Lower `minimumSupportedVersion` to the oldest version you still want to allow
- [ ] Re-upload

## QA — verify before going live

Two manual paths:

**Allowed-in path (default state):**
1. Build the app.
2. Confirm `force-update.json` has `forceUpdateRequired: false` and `minimumSupportedVersion` ≤ current `CFBundleShortVersionString`.
3. Launch — app should load normally to login or dashboard.

**Blocked path:**
1. Edit your local `force-update.json` to set `minimumSupportedVersion` to some absurdly high value (e.g. `99.0.0`) and re-upload.
2. Force-quit and relaunch the app.
3. Confirm the full-screen "Update Required" page appears with no way to dismiss.
4. Tap **Update App** — App Store should open to the Driver Hub product page.
5. Restore `force-update.json` to `1.0.0` after testing.

**DEBUG-only override (no JSON edit):**
In a debug build you can call:
```swift
ForceUpdateService.shared.forceShowForTesting()
ForceUpdateService.shared.forceHideForTesting()
```

## Field reference

| Field                     | Type   | Purpose                                                                |
|---------------------------|--------|------------------------------------------------------------------------|
| `minimumSupportedVersion` | string | Hard floor. Anything below MUST update.                                |
| `latestVersion`           | string | Newest released version. Used together with `forceUpdateRequired`.     |
| `forceUpdateRequired`     | bool   | Master kill-switch. When `true`, anyone below `latestVersion` blocked. |
| `updateMessage`           | string | User-facing copy on the blocking screen.                               |
| `appStoreURL`             | string | Direct App Store link. The "Update App" button opens this.             |

## Supabase CDN caching behavior

Supabase Storage serves public objects through a CDN that caches responses (default `Cache-Control: max-age=3600`). Without intervention, flipping `forceUpdateRequired` would take up to an hour to propagate — unacceptable for a kill-switch.

**This is solved automatically inside the app.** Every fetch in `ForceUpdateService.fetchConfig`:

- Appends a unique `?t=<epoch-seconds>` query parameter — every request is a distinct CDN cache key, so the CDN must hit origin.
- Uses a dedicated **ephemeral** `URLSession` (no on-disk cache, no in-memory cache, no `URLCache.shared` sharing).
- Sets `URLRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData`.
- Sends `Cache-Control: no-cache, no-store, must-revalidate` and `Pragma: no-cache` headers.
- Calls `URLCache.shared.removeCachedResponse(for:)` against the bare URL on every fetch as belt-and-braces eviction.

Net result: kill-switch flips are visible to clients on their **next launch**, not after CDN expiry.

You do **not** need to manually configure Cache-Control on the Supabase object — the iOS client bypasses upstream caching by design.

## Failure modes (intentional)

- DNS down → user lets in.
- 5xx from host → user lets in.
- Malformed JSON → user lets in.
- 30-second slow response → request times out at `Config.ForceUpdate.requestTimeout` (default 4s) → user lets in.

This is by design. The kill-switch is a soft protective measure, not a license server.
