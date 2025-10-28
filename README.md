# lcod-cli

Command-line tooling for installing and interacting with LCOD kernels. The CLI wraps existing runtimes (Node, Rust, Java…) and exposes a unified user experience.

## Highlights (planned)

- One-line installation (`curl … | bash` / `Invoke-WebRequest … | iex`) with automatic self-update.
- Kernel management commands: list, install/update from local binaries, set default, remove.
- Cache maintenance helpers (`lcod cache clean`, `lcod cache status`).
- Runtime wrapper (`lcod run <compose-or-component> --kernel <id> --set key=value`) that normalises environment variables, logging, and exit codes.
- Hooks for benchmarking and diagnostics after releases.

## Layout

```
scripts/
  lcod               # Bash entry point
  lib/common.sh      # Shared helpers (logging, argument parsing)
powershell/
  lcod.ps1           # PowerShell entry point for Windows users
docs/
  bootstrapping.md   # Installation and self-update internals (TBD)
```

The CLI is intentionally thin. Most responsibilities live in `lcod-release` (version manifest, cascade workflows) and the individual kernels.

## Installation

Install the CLI globally with a single command:

```
curl -fsSL https://raw.githubusercontent.com/lcod-team/lcod-cli/main/scripts/install.sh | bash
```

Windows / PowerShell:

```
irm https://raw.githubusercontent.com/lcod-team/lcod-cli/main/powershell/install.ps1 | iex
```

Both installers update an existing `lcod` executable when it is writable in your `PATH`; otherwise they pick a user-scoped directory such as `~/.local/bin` or `%USERPROFILE%\bin` and create it if necessary.

The CLI checks for updates (itself and the installed kernels) every 24 hours by default. Adjust the interval via `LCOD_AUTO_UPDATE_INTERVAL=<seconds>` or disable the behaviour with `LCOD_DISABLE_AUTO_UPDATE=1`.

## Getting started

1. Clone the repository:

   ```
   git clone git@github.com:lcod-dev/lcod-cli.git
   cd lcod-cli
   ```

2. Run the local bootstrap script (under development):

   ```
   ./scripts/lcod --help
   ```

3. For Windows PowerShell:

   ```
   pwsh -File powershell/lcod.ps1 --help
   ```

4. Install a kernel runtime either from a local path or directly from the latest release:

   ```
   # download the appropriate lcod-run archive (auto-detects platform, fetches latest release)
   ./scripts/lcod kernel install rs

   # or copy an existing binary that you built locally
   ./scripts/lcod kernel install dev --path /path/to/lcod-run --version 0.1.13

   ./scripts/lcod kernel ls
   ```

   Set `LCOD_RELEASE_REPO=owner/repo` to point the downloader at a different release source if needed (defaults to `lcod-team/lcod-kernel-rs`).

5. Execute composes via the default runtime:

   ```
   # forward arguments to lcod-run (e.g. --compose, --input, ...)
   lcod run -- --compose path/to/compose.yaml --input input.json

   # pick an explicit kernel when multiple runtimes are installed
   lcod run --kernel node -- --compose demo.yaml
   ```

## Roadmap

- Integrate with `lcod-release` to consume the canonical `VERSION` manifest.
- Implement daily self-update checks (timestamped cache under `~/.lcod`).
- Back the manifest with JSON to track installed kernels and default selection.
- Add benchmark runners once the core commands are stable.

Contributions and RFCs should be documented in `docs/` before features graduate from experimental status.
