# Set up Ram Meter

**AI-generated documentation.**

## Agentic setup

Use this checklist when an agent is installing Ram Meter for someone. It requires macOS 14 or later. Start with the [latest release](https://github.com/gclark-haven/ram-meter/releases/latest).

1. Download the DMG and its matching `.sha256` file from the same release into a temporary folder. In that folder, run `shasum -a 256 -c` followed by the checksum filename. Continue only if the result is **OK**.
2. Mount the DMG with `hdiutil attach -readonly -nobrowse "<downloaded DMG>"`. Confirm the mounted volume contains `Ram Meter.app`. Copy it to `/Applications/Ram Meter.app`, or to `~/Applications/Ram Meter.app` if the system Applications folder is unavailable. If Ram Meter is already installed, check its version and confirm the intended update with the person before replacing it.
3. Detach the mounted volume. Run `open "<installed app path>"` and confirm the menu bar shows the ram and **CPU %** followed by **RAM %**. Click it to check the **CPU** and **RAM** views. If macOS blocks the launch, hand the first-launch decision to the person using the Mac. [First-launch steps](#if-macos-blocks-the-first-launch)

## Human setup

1. On the [latest release page](https://github.com/gclark-haven/ram-meter/releases/latest), download the `.dmg` under **Assets**.
2. Open the disk image and drag **Ram Meter** to **Applications**.
3. Open **Ram Meter** from **Applications**. Look for the ram and **CPU %** followed by **RAM %** in the menu bar. Click it to see the **CPU** and **RAM** charts.

The disk image includes an app for Apple silicon and Intel Macs running macOS 14 or later.

### If macOS blocks the first launch

This download is ad hoc signed and has no Apple notarization. After trying to open the app, go to **System Settings → Privacy & Security**. If **Open Anyway** appears for Ram Meter, select it and confirm. This makes an exception for Ram Meter on that Mac. Some managed Macs may restrict this option. [Apple’s first launch instructions](https://support.apple.com/en-us/102445)

## Open Ram Meter at login

Ram Meter can open automatically after you sign in to macOS. Choose one setup method.

### Agentic setup

From a checkout of this repository, run the script as the signed-in Mac user. Pass the absolute path to the installed app.

```sh
zsh login-launch.sh enable "/Applications/Ram Meter.app"
zsh login-launch.sh status
```

For a per-user install, pass "$HOME/Applications/Ram Meter.app" instead. The script registers a per-user LaunchAgent and opens Ram Meter immediately. Rerun `enable` with the new path if you move the app. To remove the login entry, run `zsh login-launch.sh disable`. This leaves the app installed and any open instance running.

### Human setup

Open **System Settings → General → Login Items & Extensions**. Under **Open at Login**, click **+**, select the installed **Ram Meter.app**, and click **Add**. To stop auto-launching, select Ram Meter in that list and click **−**. [Apple’s Login Items guide](https://support.apple.com/guide/mac-help/mh15189/mac)

## What the numbers mean

- **Menu bar RAM** shows the estimated share of installed memory in use. The estimate includes wired and compressed memory and the tag-storage region where macOS reports it. It excludes file cache. Compare it with **Memory Used ÷ Physical Memory** in Activity Monitor. For CPU, compare **System + User**. Ram Meter samples about every two seconds. Activity Monitor has its own refresh setting.
- **Available capacity** appears above each chart. CPU availability is idle capacity. RAM availability is estimated from installed RAM minus the same used-memory estimate shown in the menu bar.
- **RAM workload rows** show process footprints. Shared resources can be counted in more than one footprint. Node servers with a detectable TCP listener, iOS Simulator, and Android Emulator get separate rows while running. A detected development process goes into its own group even if Codex launched it.
- **Docker run details** show guest usage inside the VM. The whole-Mac total already includes the VM.

### Read the workload charts

Click the ram and select **CPU** or **RAM**. Each chart shows the last 60 seconds. The workload rows use the same colors as the chart.

- **CPU** stacks workload shares of total Mac CPU, including Idle. A gap means Ram Meter could not reconcile the workload readings. **Observed threads** covers the processes Ram Meter can read.
- **RAM** stacks workload process footprints in GiB. The sum can exceed installed RAM because footprints can overlap. Use the separate whole-Mac readouts above the chart for used and estimated available RAM.

## See technical stats

Open **Stats for nerds** below the workload list. **Busy core equivalents** estimates how many logical CPUs would be fully occupied by the sampled load. For example, 25% CPU on a Mac with 8 logical CPUs is 2 busy core equivalents.

**Page-ins** and **Page-outs** show virtual memory activity per second. They measure paging, while RAM hardware read/write bandwidth is a separate metric.

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
