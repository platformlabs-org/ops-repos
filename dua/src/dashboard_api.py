import os
import requests
import json

class DashboardApi:
    """
    Mock/Implementation of Microsoft Dashboard API interaction.
    Since we cannot easily get AAD tokens in this environment without proper secrets,
    this class structures the logic.
    """
    def __init__(self, client_id=None, client_secret=None, tenant_id=None):
        self.client_id = client_id or os.environ.get("MS_CLIENT_ID")
        self.client_secret = client_secret or os.environ.get("MS_CLIENT_SECRET")
        self.tenant_id = tenant_id or os.environ.get("MS_TENANT_ID")
        self.api_base = "https://manage.devcenter.microsoft.com/v1.0/my"
        self.token = None

    def authenticate(self):
        if not (self.client_id and self.client_secret and self.tenant_id):
            print("[DashboardApi] Missing credentials, skipping authentication.")
            return

        url = f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/token"
        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "resource": "https://manage.devcenter.microsoft.com"
        }
        try:
            resp = requests.post(url, data=data)
            resp.raise_for_status()
            self.token = resp.json().get("access_token")
            print("[DashboardApi] Authenticated successfully.")
        except Exception as e:
            print(f"[DashboardApi] Auth failed: {e}")

    def get_submission(self, submission_id):
        if not self.token:
            self.authenticate()
        if not self.token:
            raise Exception("Not authenticated to Dashboard API")

        headers = {"Authorization": f"Bearer {self.token}"}
        url = f"{self.api_base}/hardware/submissions/{submission_id}"
        print(f"[DashboardApi] Fetching submission {submission_id}")
        resp = requests.get(url, headers=headers)
        resp.raise_for_status()
        return resp.json()

    def download_assets(self, submission_id, download_dir):
        """
        Downloads initial driver and HLKX from the submission.
        """
        data = self.get_submission(submission_id)

        # Logic to parse the submission data and find download links.
        # This is hypothetical as I don't have the API response schema handy,
        # but typically it contains 'downloads' or 'packages'.
        # For DUA, we need the initial driver (the one submitted previously) and the DUA shell (HLKX).
        # Actually, 'duashell' implies a specific shell package.
        # If the user provides 'submissionid', that usually refers to the *original* submission?
        # If so, we download the driver from it.
        # Where does 'duashell' come from? Is it a separate download?
        # The prompt says: "automatically download initialdriver as well as duashell".
        # I will assume the submission contains both or the API allows fetching them.

        # For now, I'll assume the 'data' has a list of downloads.
        downloads = data.get("downloads", [])
        files_downloaded = {}

        if not os.path.exists(download_dir):
            os.makedirs(download_dir)

        # Placeholder logic
        print(f"[DashboardApi] Found {len(downloads)} downloads (Mock)")
        for item in downloads:
            # item = {'url': '...', 'type': 'driver'|'hlkx', 'name': '...'}
            url = item.get("url")
            name = item.get("name")
            if url and name:
                local_path = os.path.join(download_dir, name)
                print(f"[DashboardApi] Downloading {name}...")
                with requests.get(url, stream=True) as r:
                    r.raise_for_status()
                    with open(local_path, 'wb') as f:
                        for chunk in r.iter_content(chunk_size=8192):
                            f.write(chunk)
                files_downloaded[item.get("type")] = local_path

        return files_downloaded

    # Since I cannot really call the API, I will provide a method to
    # mock the download if env var MOCK_DOWNLOAD is set, for testing/dry-run.
    def mock_download_assets(self, submission_id, download_dir):
        print(f"[DashboardApi] Mock downloading assets for {submission_id} to {download_dir}")
        # Create dummy files
        if not os.path.exists(download_dir):
            os.makedirs(download_dir)

        driver_zip = os.path.join(download_dir, "initial_driver.zip")
        duashell_hlkx = os.path.join(download_dir, "duashell.hlkx")

        # Create a valid empty zip if needed, or just touch
        with open(driver_zip, "wb") as f:
            f.write(b"PK\x05\x06" + b"\0"*18) # Empty zip

        with open(duashell_hlkx, "wb") as f:
            f.write(b"fake hlkx content")

        return {"driver": driver_zip, "hlkx": duashell_hlkx}
