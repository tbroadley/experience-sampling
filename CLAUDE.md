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
