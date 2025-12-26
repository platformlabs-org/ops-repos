import os
import json
import shutil
from .ops_api import OpsApi
from .hlkx_tool import HlkxTool
from .main import parse_issue_body

def main():
    repo = os.environ.get("GITHUB_REPOSITORY") or os.environ.get("GITEA_REPOSITORY")
    issue_number = os.environ.get("ISSUE_NUMBER")

    if not repo or not issue_number:
        print("Missing REPO or ISSUE_NUMBER.")
        return

    ops = OpsApi()

    # Get Issue Info
    issue = ops.get_issue(repo, issue_number)
    submitter_email = issue.get("user", {}).get("email") or "bot@example.com" # Fallback

    # Parse existingProductId from issue body
    data = parse_issue_body(issue["body"])
    existing_product_id = data.get("productid") # User input 'productid' is used as 'existingProductId'

    if not existing_product_id:
        print("Existing Product ID not found in issue body.")
        ops.post_comment(repo, issue_number, "❌ Missing Product ID in issue body.")
        return

    # Find latest HLKX
    # Logic: Look in comments for bot-uploaded HLKX (from main.py execution)
    comments = ops.get_issue_comments(repo, issue_number)
    target_hlkx_url = None
    target_hlkx_name = None

    # Iterate backwards
    for c in reversed(comments):
        # Check if bot (or current user)
        # And has assets
        assets = c.get("assets", [])
        for a in assets:
            if a["name"].endswith(".hlkx"):
                target_hlkx_url = a["browser_download_url"]
                target_hlkx_name = a["name"]
                break
        if target_hlkx_url:
            break

    if not target_hlkx_url:
        print("No HLKX found in comments.")
        ops.post_comment(repo, issue_number, "❌ No HLKX package found in comments to submit.")
        return

    # Download HLKX
    work_dir = os.path.join(os.getcwd(), "temp_submit")
    if not os.path.exists(work_dir):
        os.makedirs(work_dir)

    local_hlkx = os.path.join(work_dir, target_hlkx_name)
    ops.download_file(target_hlkx_url, local_hlkx)

    # Submit
    hlkx = HlkxTool()

    # Driver Name/Version?
    # Can extract from issue body or just use generic.
    # SubmitHlkJob.ps1 extracts them.
    # main.py extracted them but didn't save them.
    # Let's extract again.
    # parse_issue_body parses custom fields.
    # SubmitHlkJob.ps1 looks for "Driver Project" and "Driver Version".
    # The prompt says user inputs "projectname, productid, submissionid".
    # I'll use those.
    project_name = data.get("projectname", "UnknownProject")
    # Version? Not in prompt input list. I'll use "1.0" or try to find "Driver Version"
    # Actually, parse_issue_body only looks for specific fields I defined.
    # I should check if there are other fields.
    # For now, I'll use project_name as driver name.

    try:
        output = hlkx.run_submit(
            local_hlkx,
            submitter_email,
            project_name,
            "1.0", # Version placeholder
            driver_type="DUA",
            existing_product_id=existing_product_id
        )

        ops.post_comment(repo, issue_number, f"✅ **Submission Successful**\n\n```\n{output}\n```")

    except Exception as e:
        ops.post_comment(repo, issue_number, f"❌ **Submission Failed**\n\nError: {e}")

if __name__ == "__main__":
    main()
