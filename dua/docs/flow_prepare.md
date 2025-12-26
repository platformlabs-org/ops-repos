# Prepare Workflow Flow

1.  **Trigger**: Issue Opened or Edited with label `DUA`.
2.  **Input**: Project Name, Product ID, Submission ID from Issue Body.
3.  **Process**:
    *   Determines pipeline type (`graphic-base`, `graphic-ext`, `npu-ext`) based on Project Name.
    *   Downloads Driver and DUA Shell from Partner Center using Submission ID.
    *   Finds target INF file based on pipeline rules.
    *   Patches INF file.
    *   Replaces driver in DUA Shell with modified driver.
    *   Packages results.
4.  **Output**: Uploads modified package and HLKX to issue comments.
