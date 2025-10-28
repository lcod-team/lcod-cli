# Bootstrapping

This document explains how the CLI initialises its workspace, which prerequisites it expects, and how the self-update flow will evolve.

## Prerequisites

| Platform | Requirements |
|----------|--------------|
| Bash     | `bash` ≥ 4, `curl`, `jq`, `python3` (optional, used for portable date arithmetic). |
| PowerShell | PowerShell 7+, `Invoke-WebRequest` (built-in). |

On macOS or Linux, install `jq` via the system package manager (`brew install jq`, `apt install jq`, …).

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

## Next steps

- Implement the `lcod kernel install` command, populating `installedKernels`.  
- Hook the self-update logic to download the latest release tarball and replace the local script.  
- Provide signed one-liners (`curl … | bash`, `Invoke-WebRequest … | iex`) that drop the script into `~/.local/bin/lcod` (or a PowerShell module) and schedule periodic checks.  
- Extend this document with troubleshooting steps once the installer is ready.
