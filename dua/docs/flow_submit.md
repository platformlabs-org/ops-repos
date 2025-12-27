# Submit Workflow Flow

1.  **Trigger**: Comment `/submit` on `DUA` issue.
2.  **Process**:
    *   Scans issue comments for the latest attachment ending in `.hlkx`.
    *   Downloads the HLKX file.
    *   Uploads the HLKX file to Partner Center using the Submission ID (from context or re-parsing issue).
3.  **Output**: Posts confirmation comment.
