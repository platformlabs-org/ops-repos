import os
import re
import json
import zipfile
import shutil
import glob
from .ops_api import OpsApi
from .dashboard_api import DashboardApi
from .hlkx_tool import HlkxTool
from .inf_patcher import main as run_inf_patcher  # Ensure inf_patcher has a main or callable

def parse_issue_body(body):
    """
    Parses key-value pairs from issue body.
    Expected format:
    ### Project Name
    ...
    ### Product ID
    ...
    ### Submission ID
    ...
    """
    data = {}
    patterns = {
        "projectname": r"###\s*Project\s*Name\s*\n\s*(.+?)\s*(\n|$)",
        "productid": r"###\s*Product\s*ID\s*\n\s*(.+?)\s*(\n|$)",
        "submissionid": r"###\s*Submission\s*ID\s*\n\s*(.+?)\s*(\n|$)",
        # Also grab 'existingProductId' if present, or alias productid
        "existingproductid": r"###\s*Existing\s*Product\s*ID\s*\n\s*(.+?)\s*(\n|$)",
    }

    for key, pattern in patterns.items():
        match = re.search(pattern, body, re.IGNORECASE | re.MULTILINE)
        if match:
            data[key] = match.group(1).strip()

    return data

def identify_inf_files(driver_path, product_name):
    """
    Matches product name keywords to INF files.
    Keywords: Graphics, Base, Ext, NPU
    Files: iigd_dch.inf, iigd_ext.inf, npu_extension.inf
    """
    pname = product_name.lower()
    target_inf = None

    # Logic from prompt
    if "graphics" in pname:
        if "base" in pname:
            target_inf = "iigd_dch.inf"
        elif "ext" in pname:
            target_inf = "iigd_ext.inf"
    elif "npu" in pname:
        if "ext" in pname: # "Ext INF Template"
            target_inf = "npu_extension.inf"

    if not target_inf:
        print(f"[Warn] Could not match product name '{product_name}' to a known INF file.")
        return None

    # Find the file in driver_path recursively
    found_files = glob.glob(os.path.join(driver_path, "**", target_inf), recursive=True)
    if not found_files:
        print(f"[Warn] Target INF {target_inf} not found in {driver_path}")
        return None

    return found_files[0]

def patch_inf(inf_path, project_name):
    from .inf_patcher import process_inf_file

    config_path = os.path.join(os.path.dirname(__file__), "..", "config", "config.json")
    try:
        process_inf_file(inf_path, project_name, config_path)
        return True
    except Exception as e:
        print(f"[Error] Failed to patch INF: {e}")
        return False

def main():
    repo = os.environ.get("GITHUB_REPOSITORY") or os.environ.get("GITEA_REPOSITORY") # e.g. owner/repo
    issue_number = os.environ.get("ISSUE_NUMBER")
    if not repo or not issue_number:
        print("Missing REPO or ISSUE_NUMBER env vars.")
        return

    ops = OpsApi()
    issue = ops.get_issue(repo, issue_number)

    data = parse_issue_body(issue["body"])
    print(f"Parsed Issue Data: {data}")

    project_name = data.get("projectname")
    submission_id = data.get("submissionid")

    if not project_name or not submission_id:
        print("Missing Project Name or Submission ID in issue.")
        return

    # 1. Download Assets
    dash = DashboardApi()
    work_dir = os.path.join(os.getcwd(), "temp_dua")

    # Try actual download first, fall back to mock ONLY if explicit env var set or fails?
    # Actually, we should try real download if credentials exist.
    if dash.client_id and dash.client_secret:
        try:
            print("Attempting to download assets from Dashboard API...")
            assets = dash.download_assets(submission_id, work_dir)
        except Exception as e:
            print(f"Dashboard API download failed: {e}")
            assets = {}
    else:
        print("No Dashboard credentials found.")
        assets = {}

    # If assets are empty, maybe we are in test mode?
    if not assets and os.environ.get("DUA_MOCK_MODE") == "1":
         print("Using MOCK download due to DUA_MOCK_MODE=1")
         assets = dash.mock_download_assets(submission_id, work_dir)

    if not assets:
        print("Failed to download assets (and no mock mode).")
        ops.post_comment(repo, issue_number, "❌ Failed to download initial driver and shell from Dashboard.")
        return

    driver_zip = assets.get("driver")
    duashell_hlkx = assets.get("hlkx")

    if not driver_zip or not duashell_hlkx:
        print("Missing driver or hlkx in downloaded assets.")
        return

    # 2. Unzip Driver
    extract_dir = os.path.join(work_dir, "extracted_driver")
    try:
        with zipfile.ZipFile(driver_zip, 'r') as z:
            z.extractall(extract_dir)
    except zipfile.BadZipFile:
        print("Downloaded driver is not a valid zip file.")
        ops.post_comment(repo, issue_number, "❌ Downloaded driver file is invalid.")
        return

    # 3. Identify and Patch INF
    product_desc = data.get("productid", "")
    inf_file = identify_inf_files(extract_dir, product_desc)

    if inf_file:
        print(f"Patching {inf_file} for project {project_name}")
        if patch_inf(inf_file, project_name):
            print("Patching successful.")
        else:
            ops.post_comment(repo, issue_number, "❌ Failed to patch INF file.")
            return
    else:
        ops.post_comment(repo, issue_number, "⚠️ Could not identify target INF file or file not found.")
        return

    # 4. HlkxTool DUA
    hlkx = HlkxTool()
    output_hlkx = os.path.join(work_dir, "processed.hlkx")

    try:
        hlkx.run_dua(duashell_hlkx, extract_dir, output_hlkx)
    except Exception as e:
        ops.post_comment(repo, issue_number, f"❌ HlkxTool DUA failed: {e}")
        return

    # 5. Upload Results
    output_driver_zip = os.path.join(work_dir, "processed_driver") # shutil.make_archive adds .zip
    shutil.make_archive(output_driver_zip, 'zip', extract_dir)
    output_driver_zip += ".zip"

    comment_body = f"""
✅ **DUA Processing Complete**
Project: {project_name}
Submission ID: {submission_id}

Processed Driver and HLKX attached.
"""
    comment = ops.post_comment(repo, issue_number, comment_body)
    comment_id = comment["id"]

    ops.upload_attachment(repo, comment_id, output_hlkx)
    ops.upload_attachment(repo, comment_id, output_driver_zip)
    print("Upload complete.")

if __name__ == "__main__":
    main()
