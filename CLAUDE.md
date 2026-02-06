# Experience Sampling App

## Build, Codesign, and Restart

After making changes to the Swift code, rebuild, codesign, and restart with:

```bash
source .env && \
swiftc -O -framework AppKit -framework SwiftUI ExperienceSampling/ExperienceSampling.swift -o /tmp/ExperienceSampling.app/Contents/MacOS/ExperienceSampling && \
codesign --force --sign "$CODESIGN_CERT" /tmp/ExperienceSampling.app && \
rm -rf /Applications/ExperienceSampling.app && \
cp -R /tmp/ExperienceSampling.app /Applications/ && \
pkill -x ExperienceSampling; sleep 0.5; open /Applications/ExperienceSampling.app
```

The certificate name is configured in `.env`.

## Project Structure

- Single-file Swift app: `ExperienceSampling/ExperienceSampling.swift`
- App bundle info: `ExperienceSampling/Info.plist`
- Installed location: `/Applications/ExperienceSampling.app`

## Data Storage

Data is stored in `~/Library/Application Support/ExperienceSampling/`:
- `responses.json` - Experience sampling responses
- `pomodoro-sessions.json` - Pomodoro session history

## Gotchas

- **JSON date encoding/decoding must match**: When using `JSONEncoder` with `.iso8601` date strategy, the corresponding `JSONDecoder` must also use `.iso8601`. The default decoder strategy (`.deferredToDate`) expects a `Double`, not an ISO 8601 string, and `try?` silently swallows the mismatch — causing data loss on reload.
- **`try?` can hide data-destroying bugs**: The `load()` methods use `try?` to decode JSON. If decoding fails silently, the in-memory array resets to `[]`, and the next `save()` overwrites the file. Be careful when changing encoding strategies or data models.
