# Bootstrapping

This document explains how the CLI initialises its workspace, which prerequisites it expects, and how the self-update flow will evolve.

## Prerequisites

| Platform | Requirements |
|----------|--------------|
| Bash     | `bash` ≥ 4, `curl`, `jq`, `tar`, `unzip` (for release extraction), `python3` (optional, date arithmetic fallback). |
| PowerShell | PowerShell 7+, `Invoke-WebRequest` (built-in). |

On macOS or Linux, install `jq` via the system package manager (`brew install jq`, `apt install jq`, …).

### Installer shortcuts

- Shell:

  ```
  curl -fsSL https://raw.githubusercontent.com/lcod-team/lcod-cli/main/scripts/install.sh | bash
  ```

- PowerShell:

  ```
  irm https://raw.githubusercontent.com/lcod-team/lcod-cli/main/powershell/install.ps1 | iex
  ```

Both installers reuse an existing writable `lcod` binary when found on your `PATH`; otherwise they fall back to user-friendly directories such as `~/.local/bin` (Unix) or `%USERPROFILE%\bin` (Windows).

## State directory layout

The CLI stores its state under `~/.lcod` (configurable via environment variables):

```
~/.lcod/
  bin/                 # future shims/wrappers
  cache/               # downloaded kernels and artefacts
  config.json          # installed kernels + default selection
  last-update          # timestamp of the last update check
  latest-version.json  # cached upstream version metadata
```

`config.json` is initialised automatically with the following shape:

```json
{
  "defaultKernel": null,
  "installedKernels": [],
  "lastUpdateCheck": null
}
```

Future commands will append entries to `installedKernels` with fields such as `id`, `version`, and `path`.

## Version discovery

- `lcod version` now checks `latest-version.json`.  
- If the cache is older than 24 hours (or missing), the CLI fetches `https://raw.githubusercontent.com/lcod-dev/lcod-release/main/VERSION` and refreshes both the cache and the `config.json:lastUpdateCheck` timestamp.  
- When the upstream version differs from the local CLI version, the command reports that an update is available.

PowerShell and Bash share the same state directory, so running the command from either shell keeps the cache in sync.

## Kernel management primitives

- `lcod kernel install <id>` supports two modes:
  - With no extra flags (`lcod kernel install rs|node|java`), the CLI resolves the matching GitHub repository, fetches the latest release, auto-detects the local platform, and installs the binary under `~/.lcod/bin/<id>`.
  - `--from-release [--version <semver>] [--platform <id>]` forces release mode with explicit overrides; keep `--version` handy if you need to pin a specific runtime.
  - `--path <binary> [--version <semver>]` copies an existing executable, clears macOS quarantine attributes, and records the entry in `config.json`. Use `--force` to overwrite an existing install.
- `lcod kernel ls` prints the recorded kernels, their version metadata, and whether they are the default runtime.
- `lcod kernel default <id>` switches the preferred runtime; the value falls back to `null` if you later remove that kernel.
- `lcod kernel remove <id>` deletes the managed binary (only if it lives under `~/.lcod/bin/`) and prunes the manifest.
- `lcod run [--kernel <id>] [--] <args...>` executes the chosen runtime (defaulting to the configured default kernel) and forwards all arguments to it; `.jar` artifacts use `java -jar`, `.mjs/.js` use `node`, and native binaries are executed directly.

For custom release sources, export `LCOD_RELEASE_REPO=owner/repo` before running the command (it defaults to `lcod-team/lcod-kernel-rs`).

## macOS quarantine note

When downloading the Rust kernel (`lcod-run`) outside of Homebrew, macOS may quarantine the binary.
After extraction, the CLI will run `xattr -cr <binary>` to strip the quarantine bits.
Until the install command is wired, you can manually apply:

```
xattr -cr path/to/lcod-run
```

This is a no-op on other platforms.

## Next steps

- Implement the `lcod kernel install` command, populating `installedKernels`.  
- Hook the self-update logic to download the latest release tarball and replace the local script.  
- Provide signed one-liners (`curl … | bash`, `Invoke-WebRequest … | iex`) that drop the script into `~/.local/bin/lcod` (or a PowerShell module) and schedule periodic checks.  
- Extend this document with troubleshooting steps once the installer is ready.
