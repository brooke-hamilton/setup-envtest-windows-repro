# Windows setup-envtest launch reproduction

Reproduction of [the original report](https://gist.github.com/brooke-hamilton/24d82141fe9bbd5418f94bacd211eaf3).
It isolates process launch from Kubernetes asset downloads and Radius tests.
The independent Go module pins `setup-envtest` to `v0.24.1`; no Radius checkout
is used or modified.

## Instructions for Copilot on a second Windows machine

If asked "Try to reproduce the issue - look at the README for what to do",
follow this runbook. All required source is in this repository; the gist and
the original conversation are not needed to execute the experiment.

**Objective:** determine whether native Windows AMD64 exhibits the same launch
failure observed on native Windows ARM64. Do not try to fix the machine or
assume that failure is the expected result on every architecture.

The original Radius command failed before any tests or Kubernetes downloads:

```text
go tool setup-envtest: fork/exec ...\setup-envtest.exe: The requested operation requires elevation.
```

The executable name is not a reserved Windows filename. The hypothesis is
filename-sensitive Windows elevation/compatibility handling when an explicit
execution-level manifest is absent. The exact Windows mechanism is unproven.

### Prepare and execute

1. Work in a local clone of this repository, in a normal **non-administrator**
   terminal. Do not run any Radius checkout, tests, or Kubernetes tooling.
2. Check for PowerShell 7 (`pwsh`) and a native Windows Go installation. Prefer
   **Go 1.27.4** to match the ARM64 baseline; the module requires at least
   1.27.3. On an AMD64 machine, use AMD64 PowerShell and Go, not 32-bit Go or
   an ARM64 cross-compilation target. If a prerequisite is missing, report
   it and ask before installing anything.
3. Use the commands below to record architecture and run the existing harness.
   If `go` is not on PATH, locate the installed executable and pass its absolute
   path with `-Go`; do not assume the original machine's user-specific path.
4. Inspect the new report and help/error output. Report actual outcomes even if
   every executable launches. Do not modify the harness to force a 740 result.

From PowerShell 7 in the cloned repository:

```powershell
$PSVersionTable.PSVersion
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
go version
go env GOOS GOARCH GOHOSTOS GOHOSTARCH
.\repro.ps1
```

If starting from Windows PowerShell 5.1, run `pwsh -NoProfile` first. Do not
change execution policy if script execution is blocked; report the exact error
and ask for guidance. Likewise, do not elevate, disable UAC, edit registry or
compatibility settings, use `runas`, or bypass security/download restrictions.
Report the exact blocked URL if a dependency download fails.

The harness sets `GOWORK=off` only for its child processes. It requires a native
Windows Go target (`GOOS=windows`, `GOARCH=GOHOSTARCH`). For this AMD64 comparison,
also verify OS/process architecture is `X64`, Go host/target architecture is
`amd64`, and the resulting PE machine type is `AMD64 (0x8664)`. If these do not
match, report the mismatch and do not label it a native AMD64 result.

### Read and report results

The harness prints its evidence directory. To inspect the newest run:

```powershell
$run = Get-ChildItem -LiteralPath .\results -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$report = Get-Content -LiteralPath (Join-Path $run.FullName 'report.json') -Raw |
    ConvertFrom-Json
$report.os
$report.goEnvironment
$report.module
$report.binaries | Format-List
$report.launches | Format-Table label, launched, timedOut, exitCode, win32Error
$report.manifestExperiment | Format-List
$report.completed
$report.failure
# Inspect the files named by stdoutFile/stderrFile for each launched command.
```

Report Windows edition/build, OS/process/Go/PE architectures, elevation state,
Go and module versions, and all five comparison outcomes described below.
Verify that all three baseline SHA256 hashes match **within this run**.
AMD64 hashes need not match ARM64 hashes, nor do separate builds necessarily
have identical hashes across machines. Record original manifests, the injected
manifest result, and matching compatibility entries/UAC settings.

`go-tool-help.launched=true` means **Go** launched, not necessarily its child
tool: inspect its exit code and stderr. For direct-launch comparisons,
`launched=false` with `win32Error=740` confirms the elevation failure.
`launched=true`, `timedOut=false`, exit 2, and actual setup-envtest usage output
confirm a successful help launch. Other errors/timeouts are inconclusive, not
evidence of the same failure. Check `completed` and `failure`; the harness can
complete while recording process failures.

Compare with the ARM64 baseline below:

- If setup-named copies fail with 740 but the neutral copy and manifest-patched
  setup copy launch, the behavior is **not exclusive to ARM64**.
- If all copies launch on AMD64, the failure was **not reproduced on that
  machine**. That does not establish ARM64 as the cause: Windows build, policy,
  compatibility handling, and security software may differ.
- If results differ in another way, report the exact matrix without forcing
  either conclusion. An existing manifest causes injection to be skipped;
  that is not the same experiment as the manifest-free ARM64 baseline.

Leave evidence locally in the ignored `results` directory. Do not commit logs,
executables, private configuration, or machine-specific paths. Do not create
issues, push changes, or publish findings unless separately instructed.

## Run

Use non-administrator PowerShell 7 on Windows, with Go 1.27.3 or later:

```powershell
.\repro.ps1
# If Go is not on PATH:
.\repro.ps1 -Go 'C:\path\to\go.exe'
```

The harness refuses an elevated process. It resolves the module's dependencies
using the existing Go configuration (with `GOWORK=off` for process-local
isolation) and runs `go mod tidy` to persist the
dependency graph and checksums. The first run may download Go modules and build
the tool. It does not install additional tooling, fetch Kubernetes assets,
change UAC/compatibility settings, or publish anything.

## Controlled comparisons and evidence

Each run saves `results\<timestamp>-<id>\report.json`, command output, and two
executable copies. Results are ignored by Git and remain on this machine.
Home and repository prefixes in reports/output are replaced with placeholders;
reports intentionally omit the full Go environment and unrelated registry data.
Inspect output before sharing it because dependency errors can contain network
addresses from local configuration.

The harness records Windows build and architecture, actual token elevation,
PowerShell/Go/module versions, SHA256 hashes, PE machine types, embedded manifest
text, selected read-only UAC settings, the compatibility environment variable,
and matching per-executable compatibility layer entries (current user/machine).
It then directly launches each binary using `UseShellExecute = false` and
`--help`, with bounded waits and concurrently drained output streams:

1. The module-pinned tool via `go tool setup-envtest --help`.
2. Its original cached executable.
3. A byte-identical `setup-envtest.exe` copy.
4. A byte-identical `envtest-probe.exe` in the same directory as the setup copy.
5. If no embedded manifest exists, the setup copy at that exact same path after
   adding an explicit `asInvoker` execution-level manifest.

The fifth experiment changes the PE resource section and hash, not the original
Go cache binary. Its recorded manifest/hash describe the final setup copy;
`binaries` records the baseline hashes before modification. The neutral copy
remains unchanged. The manifest experiment uses Windows resource APIs, preserving
other resources, and skips rather than overwrites a pre-existing manifest.

Win32 error 740 is a **launch failure**. A launched help command exiting 2 is
expected for this tool and is not an elevation failure. Nonzero help exits are
recorded without treating them as harness failure. Build/download errors and
timeouts are explicitly recorded; a completed report alone does not establish
that the original error reproduced.

## Interpretation and limitations

The original report established that a cached `setup-envtest.exe` failed with
740, while a renamed copy in another directory launched. It did not isolate
filename from directory and did not inspect the PE architecture or manifest.
See the local run reports for newly confirmed observations.

### Confirmed on this machine

On November 10, 2026, the harness reproduced the failure without elevation on
Windows 11 Enterprise ARM64, version 26H2, build 26300.9725, using native ARM64
PowerShell 7.6.9 and Go 1.27.4. The registry's legacy `ProductName` string says
"Windows 10 Enterprise"; the OS caption identifies Windows 11.

| Comparison | Result |
| --- | --- |
| `go tool setup-envtest --help` | Go exited 1: child launch requires elevation |
| Cached `setup-envtest.exe`, direct launch | Win32 740; process not started |
| Same-directory `setup-envtest.exe`, unchanged copy | Win32 740; process not started |
| Same-directory `envtest-probe.exe`, unchanged copy | Help printed; exit 2 |
| Setup copy at the same path, with `asInvoker` manifest | Help printed; exit 2 |

All three baseline binaries were ARM64 PE images (`0xAA64`), 7,574,528 bytes,
with no embedded manifest. Their identical SHA256 was
`539D20CEB54E45F53BC24618E2A8230F4376D766FB220AA8EDB94351A4C53721`.
Adding the manifest changed only the local setup copy, which remained ARM64;
its SHA256 became
`C9383E871616E5AD124D4C2DEF330802DDF5B2DE272868CC41ACC3B9FBA196AB`.
No matching current-user/machine compatibility layer entries were found for
the three paths, and `__COMPAT_LAYER` was unset. `EnableLUA` and
`EnableInstallerDetection` were both 1; these values alone do not identify
the mechanism.

A same-directory filename-dependent result narrows the cause but does not name
the Windows mechanism. Likewise, a successful `asInvoker` experiment shows the
effect of an execution-level manifest; it does not prove classic installer
detection is responsible. That documented mechanism has restrictions including
32-bit application applicability, so its relevance to ARM64 must not be assumed.
Read-only checks here do not exhaust application compatibility databases,
enterprise policy, security products, or all resource language variants.

No terminal elevation or policy changes are needed or attempted. Retained
binaries and logs can be removed by deleting a specific completed run directory;
the original Go cache is never modified.
