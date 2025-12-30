# Sign Repository

This repository provides an automated workflow for signing drivers and files. It is integrated with Gitea Actions to process requests via Issues.

## Directory Structure

```text
sign/
├── .gitea/workflows/   # Gitea Actions workflow definitions
├── scripts/
│   ├── modules/        # Shared PowerShell modules (OpsApi.psm1)
│   └── steps/          # Step-by-step scripts used in the workflow
├── tools/              # External tools (e.g., whosinf.exe)
└── README.md           # This file
```

## Workflow Usage

The signing process is triggered by creating an Issue in this repository.

### 1. Trigger
*   **Event**: Opening or Reopening an Issue.
*   **Conditions**: The Issue must contain specific fields parsed by the workflow.

### 2. Issue Format
The Issue body is parsed to extract configuration parameters. Ensure the following sections are present:

*   `### Driver Sign Type`:
    *   `Lenovo Driver`: Standard driver signing (checks for `whosinf` = Lenovo).
    *   `Other Driver`: General driver signing.
    *   `Sign File`: Signs individual files (`.dll`, `.sys`, `.exe`) directly.
*   `### Do you need CAB packaging?`:
    *   `Yes`: Repackages the signed driver into a `.cab` file.
    *   `No`: Skips CAB packaging.
*   `### Architecture Type`:
    *   `AMD64`: For Windows 10 x64.
    *   `ARM64`: For Windows 10 ARM64.
*   `### Driver Version`:
    *   The version string of the driver.

### 3. Attachments
*   You must attach a single `.zip` file to the Issue.
*   For `Lenovo Driver` / `Other Driver`: The zip should contain the driver files (including `.inf`).
*   For `Sign File`: The zip should contain the binaries to be signed.

## Output

Upon successful completion:
1.  The workflow creates a signed archive (and optional CAB file).
2.  The artifacts are uploaded as attachments to a comment on the original Issue.
3.  The Issue title is updated to indicate completion (e.g., `[Driver Sign Request]: <AttachmentName> Signed`).

## Scripts Overview

*   `pre-check.ps1`: Validates Issue format and attachment.
*   `download-and-extract.ps1`: Downloads the attachment and prepares the workspace.
*   `sign-files.ps1`: Signs binaries using the configured certificate.
*   `inf2cat.ps1`: Generates `.cat` files for drivers (if applicable).
*   `make-cab.ps1`: Creates a `.cab` package if requested.
*   `archive-output.ps1`: Zips the final results.
*   `update-issue.ps1`: Uploads results back to the Gitea Issue.
