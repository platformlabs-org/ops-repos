# BSOD Pipeline

The **BSOD Pipeline** is an automated system designed to analyze Windows crash dumps. It handles the entire lifecycle of a crash report, from fetching the dump file to analyzing it with Windbg (`kd`) and publishing the results.

## Requirements

*   **PowerShell 5.1** or newer (PowerShell Core 7+ recommended).
*   **Debugging Tools for Windows**: The pipeline expects `kd.exe` to be available (typically in `windbg/x64`).
*   **7-Zip**: Required for extracting archives. The pipeline looks in `tools/7-Zip/7z.exe` or standard installation paths.

## Directory Structure

*   `scripts/`: Contains all PowerShell scripts and modules.
    *   `cli.ps1`: The main entry point for the pipeline.
    *   `settings.psd1`: Configuration file (paths, timeouts, API endpoints).
*   `tools/`: Third-party tools (e.g., 7-Zip).
*   `windbg/`: Debugging Tools for Windows (must contain `kd.exe`).

## Workflow

The pipeline executes in sequential **Phases**:

1.  **Init**: Initializes the environment, loads settings, and prepares the workspace.
2.  **Fetch**: Downloads the crash dump file (and related attachments) from the source (e.g., MinIO/S3 or Gitea).
3.  **Analyze**: Runs the configured analyzers (currently `kd`) against the dump file to extract failure buckets, stack traces, and system info.
4.  **Persist**: Saves the analysis results to the backend API.
5.  **Publish**: Posts a summary of the analysis back to the issue tracker (e.g., Gitea comments).
6.  **Finalize**: Cleans up temporary files and updates the status of the event.

## Usage

### Running the Pipeline

The pipeline is typically triggered automatically. However, it can be run manually via the CLI script.

```powershell
./scripts/cli.ps1 -Phase All
```

### Local Debugging

For development and testing, you can run the pipeline against a local dump file without connecting to external services for fetching.

```powershell
./scripts/cli.ps1 -LocalFile "C:\path\to\memory.dmp"
```

This command:
*   Bypasses the **Fetch** phase.
*   Uses the provided local file as the analysis target.
*   Proceeds with **Analyze**, **Persist**, etc. (depending on configuration and mocking).

## Configuration

Configuration settings are stored in `scripts/settings.psd1`. Key settings include:
*   **Paths**: Locations for `kd.exe`, `7z.exe`, and temporary workspaces.
*   **Auth**: Credentials for Keycloak.
*   **Endpoints**: API URLs for the backend and issue tracker.
*   **Pipeline**: Toggles for enabling/disabling specific phases (e.g., Persist, Publish).
