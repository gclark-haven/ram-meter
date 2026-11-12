# Set up Ram Meter

**AI-generated documentation.**

Use the menu bar for a quick CPU and RAM reading. Open the popover when you want to see which workloads are using those resources.

## Install Ram Meter

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
