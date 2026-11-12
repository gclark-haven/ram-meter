# Set up Ram Meter

**AI-generated documentation.**

## Agentic setup

Use this checklist when an agent is installing Ram Meter for someone. It requires macOS 14 or later. Start with the [latest release](https://github.com/gclark-haven/ram-meter/releases/latest).

1. Download the DMG and its matching `.sha256` file from the same release into a temporary folder. In that folder, run `shasum -a 256 -c Ram-Meter-v1.2.0.dmg.sha256` with the actual checksum filename. Continue only if the result is **OK**.
2. Mount the DMG with `hdiutil attach -readonly -nobrowse "<downloaded DMG>"`. Confirm the mounted volume contains `Ram Meter.app`. Copy it to `/Applications/Ram Meter.app`, or to `~/Applications/Ram Meter.app` if the system Applications folder is unavailable. If Ram Meter is already installed, check its version and confirm the intended update with the person before replacing it.
3. Detach the mounted volume. Run `open "<installed app path>"` and confirm the menu bar shows the ram, **CPU %**, then **RAM used in GiB**. If macOS blocks the launch, hand the first-launch decision to the person using the Mac. [First-launch steps](#if-macos-blocks-the-first-launch)

## Human setup

1. On the [latest release page](https://github.com/gclark-haven/ram-meter/releases/latest), download the `.dmg` under **Assets**.
2. Open the disk image and drag **Ram Meter** to **Applications**.
3. Open **Ram Meter** from **Applications**. Look for the ram beside **CPU** and **RAM** in the menu bar.

The disk image includes an app for Apple silicon and Intel Macs running macOS 14 or later.

### If macOS blocks the first launch

This download is ad hoc signed and has no Apple notarization. After trying to open the app, go to **System Settings → Privacy & Security**. If **Open Anyway** appears for Ram Meter, select it and confirm. This makes an exception for Ram Meter on that Mac. Some managed Macs may restrict this option. [Apple’s first launch instructions](https://support.apple.com/en-us/102445)

## What the numbers mean

- **Menu bar CPU** shows busy capacity as a percentage across the whole Mac.
- **Menu bar RAM** estimates physical memory in use in GiB, including wired and compressed memory. File cache is excluded.
- **Popover RAM** compares measured process footprints. Those measurements use a different accounting method from the menu bar total.
- **Docker run details** show guest usage inside the VM. The whole-Mac total already includes the VM.

## Track a Codex command

1. Open Ram Meter and expand **Codex**.
2. Click **Copy command prefix**.
3. In the Codex chat you want to measure, use that prefix before the local command. For example:

```sh
"/Applications/Ram Meter.app/Contents/MacOS/WorkloadMeter" --track -- make test
```

The chat row appears while its registered local work runs. Shared Codex processes appear under **Shared Codex**.

## See local GitHub Actions runs

This is optional. Use it for trusted GitHub Actions runners inside Docker Desktop. The Mac needs Python 3. Each runner container needs `/usr/bin/python3` and must run under the `desktop-linux` Docker context.

1. Copy [the example config](runners.example.json) to `~/Library/Application Support/Ram Meter/runners.json`. Create the folder if needed.
2. In each entry, set **container** to the Docker container name, **runner** to the GitHub runner name, and **repository** to `owner/repository`.
3. Open Ram Meter and expand **Docker VM**. A run appears once its runner exposes the job identity. While that identity is unavailable, the group can show **Runner activity**.
