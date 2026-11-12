<p align="center"><img src="Assets/app-icon.svg" width="144" alt="Ram Meter bighorn ram logo"></p>

# Ram Meter

A native macOS menu bar meter for CPU and RAM. Open the ram in the menu bar to compare Docker, Codex, browsers, and the rest of the Mac. Expand a row for details.

The menu bar percentage shows whole-Mac CPU. In the popover, **CPU** includes idle capacity. **RAM** shows measured process footprint alongside installed memory and memory pressure. Docker guest figures describe the work inside the VM and do not add to the Mac total.

## Build and run

Requires macOS 14 or newer and Apple’s Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/gclark-haven/ram-meter.git
cd ram-meter
mkdir -p "$HOME/Applications"
zsh build.sh "$HOME/Applications/Ram Meter.app"
open "$HOME/Applications/Ram Meter.app"
```

The build creates an ad hoc signed app in the path you supply. The path must be new.

## Track a Codex command

Open **Codex** in the popover and choose **Copy command prefix**. In the chat you want to measure, use that prefix before the local command. For example:

```sh
"$HOME/Applications/Ram Meter.app/Contents/MacOS/WorkloadMeter" --track -- make test
```

Ram Meter reads the chat ID supplied by Codex and attributes the registered process tree. Recognized shared Codex processes appear under **Shared Codex**.

## Optional Docker runner details

For trusted local GitHub Actions runners inside Docker Desktop, copy [the example](runners.example.json) to `~/Library/Application Support/Ram Meter/runners.json` and set each container name, GitHub runner name, and repository. The adapter uses Docker Desktop’s `desktop-linux` context and needs Python 3 on the Mac and `/usr/bin/python3` inside each runner container. It reads Docker guest counters and the GitHub Actions identity fields of the active job. Unidentified work appears as runner activity.

All sampling runs locally. The app uses macOS process counters for the data the current user can read.
