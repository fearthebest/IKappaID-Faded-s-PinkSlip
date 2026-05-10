# KappaID & Faded's PinkSlip
The main mod of PinkSlip.

## Never used GitHub? Use GitHub Desktop (easiest)

A cloud service or AI cannot open folders on your computer or log into your GitHub account for you. You only need to do this **once**: install one app, copy your mod files into a folder, then click **Commit** and **Push**. After that, your mod is on GitHub.

1. **Create a GitHub account** (free): [https://github.com/signup](https://github.com/signup).
2. **Install GitHub Desktop** (free app for Windows): [https://desktop.github.com/](https://desktop.github.com/). Open it and **sign in** with the same GitHub account that owns this repository (or an account that has been given access).
3. **Clone this repository**: In GitHub Desktop, **File → Clone repository**. Pick the **GitHub.com** tab, select **IKappaID-Faded-s-PinkSlip**, choose a folder on your PC (for example `Documents\GitHub\IKappaID-Faded-s-PinkSlip`), then click **Clone**.
4. **Copy your mod into that folder**: Open the cloned folder in File Explorer. Copy **everything inside** your backup mod folder (for example `IKappaIDPinkSlip_Backup_v0.2.11`) **into** the cloned folder. If Windows asks about replacing `README.md`, you can choose **Skip** for that file or replace it—either is fine.
5. **Upload**: Go back to GitHub Desktop. You should see a list of changed files. At the bottom left, type a short summary (for example `Add mod files v0.2.11`), click **Commit to main**, then click **Push origin** at the top.

When **Push** finishes, refresh [the repository on the web](https://github.com/fearthebest/IKappaID-Faded-s-PinkSlip) and your files should appear.

---

## Publishing your local mod folder to GitHub (command line)

This repository is already connected to GitHub. Your mod lives on your PC (for example `IKappaIDPinkSlip_Backup_v0.2.11`). Git only tracks files **inside** the cloned folder, so copy the **contents** of your backup mod folder into this repository's root (next to `README.md`), then commit and push.

### Option A — You use this clone (Cursor, Codespaces, or another machine)

1. Copy everything from your backup folder into `/workspace` (merge with existing files; keep `.git` as-is).
2. Run:

```bash
git add -A
git status
git commit -m "Add mod sources v0.2.11"
git push -u origin main
```

If you are on a feature branch, push that branch and open a pull request into `main` instead.

### Option B — You use Git only on Windows (PowerShell)

Replace the path below with your real mod folder path.

```powershell
cd "C:\Users\mpass\Desktop\MyProjectZomboid\KappaIDPinkSlipMod\IKappaIDPinkSlip_Backup_v0.2.11"
git init
git branch -M main
git remote add origin https://github.com/fearthebest/IKappaID-Faded-s-PinkSlip.git
git pull origin main --allow-unrelated-histories
# Resolve any conflicts if README differs, then:
git add -A
git commit -m "Add mod sources v0.2.11"
git push -u origin main
```

If the remote already has commits and `git pull` is messy, clone the GitHub repo to a new folder, copy your mod files into that folder, then `git add`, `commit`, and `push` from there — that is usually simplest.

### GitHub account and access

- Sign in to GitHub and create the repository if it does not exist yet (same name as in `origin`, or change `origin` to your repo URL).
- Use HTTPS with a [personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) or SSH keys when `git push` asks for credentials.
