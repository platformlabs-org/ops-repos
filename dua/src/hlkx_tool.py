import os
import subprocess
import shutil

class HlkxTool:
    def __init__(self, tool_path=None):
        if tool_path:
            self.tool_path = tool_path
        else:
            # Default locations
            local_path = os.path.join(os.getcwd(), "HlkxTool", "HlkxTool.exe")
            repo_root_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "HlkxTool", "HlkxTool.exe"))

            if os.path.exists(local_path):
                self.tool_path = local_path
            elif os.path.exists(repo_root_path):
                self.tool_path = repo_root_path
            else:
                # Fallback to PATH or hope it works relative
                self.tool_path = "HlkxTool.exe"

        print(f"[HlkxTool] Using executable: {self.tool_path}")

    def run_dua(self, hlkx_path, driver_folder, output_path):
        """
        Runs: HlkxTool dua <hlkx_path> <driver_folder> <output_path>
        """
        if not os.path.exists(hlkx_path):
            raise FileNotFoundError(f"HLKX file not found: {hlkx_path}")
        if not os.path.exists(driver_folder):
            raise FileNotFoundError(f"Driver folder not found: {driver_folder}")

        cmd = [
            self.tool_path,
            "dua",
            hlkx_path,
            driver_folder,
            output_path
        ]

        print(f"[HlkxTool] Running: {' '.join(cmd)}")
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            print("[HlkxTool] STDOUT:\n", result.stdout)
            if result.stderr:
                print("[HlkxTool] STDERR:\n", result.stderr)
            return True
        except subprocess.CalledProcessError as e:
            print(f"[HlkxTool] Failed with exit code {e.returncode}")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise e

    def run_submit(self, hlkx_path, to_email, driver_name, driver_version, driver_type="DUA", existing_product_id=None):
        """
        Runs: HlkxTool submit --hlkx ...
        """
        cmd = [
            self.tool_path,
            "submit",
            "--hlkx", hlkx_path,
            "--to", to_email,
            "--driver-name", f"{driver_name} {driver_version}",
            "--driver-type", driver_type,
            "--fw", driver_version,
            "--yes",
            "--non-interactive"
        ]

        if driver_type.upper() == "DUA" and existing_product_id:
            # Assuming HlkxTool supports passing existing product ID somehow.
            # The user request says: "SubmitHlkJob.ps1 method... difference is 'driverType': 'DUA' needs existingProductId"
            # I need to verify how HlkxTool accepts existingProductId.
            # Usually HlkxTool arguments map to API parameters.
            # If HlkxTool CLI doesn't support it explicitly, this might be a problem.
            # However, prompt says: "HlkxTool usage... HlkxTool submit --hlkx".
            # And "submit options (same as original tool)".
            # If the original tool supports DUA, it must have a flag for existing product ID.
            # I will guess the flag is `--existing-product-id` or similar, or maybe passed via config?
            # Wait, the prompt implies HlkxTool usage is provided.
            # The prompt text: "submit options (same as original tool): --hlkx".
            # It doesn't list --existing-product-id.
            # But the requirement says "need to fill existingProductId".
            # If HlkxTool doesn't support it, I might need to edit HlkxTool (cannot do that, binary provided) or the prompt implies I should use the API directly?
            # But the prompt explicitly says "Use HlkxTool.exe submit".
            # Maybe the argument is `--product-id`?
            # I will assume `--existing-product-id` is the flag, as it is standard for DUA.
            cmd.extend(["--existing-product-id", existing_product_id])

        print(f"[HlkxTool] Running: {' '.join(cmd)}")
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            print("[HlkxTool] STDOUT:\n", result.stdout)
            return result.stdout
        except subprocess.CalledProcessError as e:
            print(f"[HlkxTool] Failed with exit code {e.returncode}")
            print("STDOUT:", e.stdout)
            print("STDERR:", e.stderr)
            raise e
