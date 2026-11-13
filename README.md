# Ram Meter

**AI-generated documentation.**

<p><img src="Assets/app-icon.svg" width="96" alt="Ram Meter bighorn ram logo"></p>

Ram Meter shows the last 60 seconds of CPU and RAM use across Docker, Codex, browsers, and other apps. Running Node servers, iOS simulators, and Android emulators get their own rows.

**[Download the DMG](https://github.com/gclark-haven/ram-meter/releases/latest)** · macOS 14 or later · Apple silicon and Intel

## CPU and RAM charts

| CPU usage by workload | RAM footprint by workload |
| --- | --- |
| <img src="Assets/screenshots/chart-cpu.png" width="440" alt="Ram Meter CPU tab with 60 seconds of stacked workload usage and idle capacity"> | <img src="Assets/screenshots/chart-ram.png" width="440" alt="Ram Meter RAM tab with per-workload history in GiB and current used and available memory"> |

## Install

- [Agentic setup](SETUP.md#agentic-setup)
- [Human setup](SETUP.md#human-setup)

The download is ad hoc signed and has no Apple notarization. If macOS blocks the first launch, follow the [first launch steps](SETUP.md#if-macos-blocks-the-first-launch).

## Set up optional details

- [Track a local Codex command](SETUP.md#track-a-codex-command)
- [See local GitHub Actions runs inside Docker](SETUP.md#see-local-github-actions-runs)
- [Understand the numbers](SETUP.md#what-the-numbers-mean)

All sampling runs on your Mac.

## Build from source

Install Apple’s Command Line Tools with `xcode-select --install`, then run these commands from the repository:

```sh
mkdir -p "$HOME/Applications"
zsh build.sh "$HOME/Applications/Ram Meter.app"
open "$HOME/Applications/Ram Meter.app"
```

Choose a new output path if the app already exists. Set `RAM_METER_UNIVERSAL=1` before the build command to include both Apple silicon and Intel.
