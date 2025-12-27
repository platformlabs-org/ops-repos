# Scripts Usage

## Environment Variables
*   `GITHUB_TOKEN`: For Gitea API.
*   `PARTNER_CENTER_CLIENT_ID`
*   `PARTNER_CENTER_CLIENT_SECRET`
*   `PARTNER_CENTER_TENANT_ID`

## Debugging
Run locally:
```powershell
./dua/scripts/entrypoints/Prepare.ps1 -IssueNumber 123 -RepoOwner owner -RepoName repo
```
Ensure env vars are set.
