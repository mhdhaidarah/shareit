# ShareIT

Share a folder, or a website running on your machine, with a real internet link. Paste one command, get a link, close the window when you are done.

No account and no port forwarding. It installs what it needs on the first run.

## Use it

Open a terminal **in the folder you want to share** and paste:

**Ubuntu / Debian**

```bash
curl -fsSL https://dl.securytik.com/shareit | bash
```

**Windows (PowerShell)**

```powershell
irm https://dl.securytik.com/shareit.ps1 | iex
```

It asks what you want to share:

| Choice | What people get |
|---|---|
| **1. Files** | A download page with every file in the folder and its subfolders. Downloads can resume. |
| **2. Website** | Your app itself. Enter `3000`, `localhost:8080` or `192.168.1.5:8080`. |

ShareIT prints the link. **Close the window, or press Ctrl+C, to end it.**

## Skip the question (Ubuntu)

```bash
curl -fsSL https://dl.securytik.com/shareit | bash -s -- files
curl -fsSL https://dl.securytik.com/shareit | bash -s -- website 3000
```

After the first run the `shareit` command also works: `shareit`, `shareit files /some/folder`, `shareit website 3000`.

On Windows, set the choice first:

```powershell
$env:SHAREIT_MODE='website'; $env:SHAREIT_TARGET='3000'; irm https://dl.securytik.com/shareit.ps1 | iex
```

## What it does to your machine

- Installs nginx and Cloudflare's `cloudflared`, once. On Windows they go in `%LOCALAPPDATA%\ShareIT`, with no admin rights needed. On Ubuntu installing needs `sudo`.
- Runs a private copy of nginx on a free local port. Your own nginx, and anything on port 80, are not touched.
- When you close it, nginx and the tunnel stop and the link dies. Nothing is uninstalled, so the next run starts straight away.
- If ShareIT installed nginx on Ubuntu, the system nginx service stays turned off.

## Safety

- **Anyone with the link can get what you share.** Share only what you mean to.
- File links carry a long random part, so they cannot be guessed. A website link opens your app directly.
- Hidden files such as `.env` and `.git`, and shortcuts that point outside the folder, are never served.
- ShareIT refuses your home folder, a drive root and system folders. To override it on Ubuntu use `--force`; on Windows set `$env:SHAREIT_FORCE='1'`.
- Links run through [Cloudflare quick tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/): free, for testing and short shares, with no uptime promise. A new link is created every time.

## Build

`shareit.sh` and `shareit.ps1` are generated. Edit the files in `src/`, then run `python3 build.py`.

## License

MIT. Made by [SecuryTik](https://securytik.com).
