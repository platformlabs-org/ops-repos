import os
import requests
import mimetypes

class OpsApi:
    def __init__(self, token=None):
        self.base_url = "https://ops.platformlabs.lenovo.com/api/v1/repos"
        self.token = token or os.environ.get("GITEA_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not self.token:
            raise ValueError("Token is required (GITEA_TOKEN)")
        self.headers = {
            "Authorization": f"token {self.token}",
            "Accept": "application/json"
        }

    def get_issue(self, repo, number):
        url = f"{self.base_url}/{repo}/issues/{number}"
        print(f"[OpsApi] GET issue {url}")
        resp = requests.get(url, headers=self.headers)
        resp.raise_for_status()
        return resp.json()

    def get_issue_comments(self, repo, number):
        url = f"{self.base_url}/{repo}/issues/{number}/comments"
        print(f"[OpsApi] GET comments {url}")
        resp = requests.get(url, headers=self.headers)
        resp.raise_for_status()
        return resp.json()

    def download_file(self, url, target_path):
        headers = self.headers.copy()
        headers["Accept"] = "application/octet-stream"
        print(f"[OpsApi] Downloading {url} -> {target_path}")
        with requests.get(url, headers=headers, stream=True) as r:
            r.raise_for_status()
            with open(target_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)

    def post_comment(self, repo, number, body):
        url = f"{self.base_url}/{repo}/issues/{number}/comments"
        print(f"[OpsApi] POST comment on #{number}")
        resp = requests.post(url, headers=self.headers, json={"body": body})
        resp.raise_for_status()
        return resp.json()

    def upload_attachment(self, repo, comment_id, filepath):
        if not os.path.exists(filepath):
            raise FileNotFoundError(f"File not found: {filepath}")

        url = f"{self.base_url}/{repo}/issues/comments/{comment_id}/assets"
        filename = os.path.basename(filepath)

        # Determine content type
        content_type, _ = mimetypes.guess_type(filepath)
        if not content_type:
            content_type = "application/octet-stream"

        print(f"[OpsApi] Uploading {filename} to comment {comment_id}")

        # Gitea API for attachment upload usually expects multipart/form-data
        with open(filepath, 'rb') as f:
            files = {
                'attachment': (filename, f, content_type)
            }
            # Note: Do not set Content-Type header manually when using 'files', requests does it.
            headers = {"Authorization": f"token {self.token}"}
            resp = requests.post(url, headers=headers, files=files)

        print(f"[OpsApi] Upload response: {resp.status_code} {resp.text}")
        resp.raise_for_status()
        return resp.json()
