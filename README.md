## 🌊 LinuxWave

A package manager for Linux software developers.

macOS? View [MacWave](https://github.com/MacWaveOrg/MacWave)

**English** · [简体中文](./README.zh-Hans.md)

> **Site notice**: the official website has moved to **[linuxwave.org](https://linuxwave.org)** (previously `linuxwave.macwave.org`).

## 🌊 Official Website

[linuxwave.org](https://linuxwave.org)

## 🌊 Supported Platform
Linux (x86_64 / arm64)
## 🌊 Latest Version

4.6.0, Release on 2026-11-24

## 🌊 What is LinuxWave?

LinuxWave is a **package manager** that runs on **Linux**, designed to host common software packages for Linux software developers.

> **A supplement, not a replacement.** Like Linuxbrew, LinuxWave only covers the common
> developer software your distro's package manager does not ship, or ships too old.
> `apt` / `dnf` / `pacman` remain the way to install system components, libraries and
> drivers. The two coexist without taking each other over: LinuxWave never installs,
> upgrades or removes a distro-managed package, and writes nowhere except its own
> install tree, its config directory and your shell startup file.

## 🌊 Why LinuxWave

1. **Lightweight design, saves disk space.** Files are pulled by the install script instead of cloning the repository, saving your disk space.
2. **One command, install common packages.** No more scattered download links.
3. **Versioned storage.** Every binary is stored as `package@version`, so multiple versions can coexist without conflicting with system tools.
4. **Optional unversioned links.** `wave link <package>` creates a plain `package` shortcut pointing at the highest installed version, and it re-points itself whenever you install or remove versions.
5. **No cache, always up to date.** Package metadata is fetched live from the `infosource` branch.
6. **10 archive formats, CI-verified.** Supports no-extension binaries, `.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar`, `.gz`, `.xz`, `.bz2`, `.conda`.
7. **Verify first, extract later.** SHA256 is checked before extraction.
8. **Resumable downloads.** Interrupted? Resume with `-C`. A file that fails
   mid-transfer is retried up to 5 times automatically, and `Ctrl-C` stops with a
   one-line message instead of a Python traceback.
9. **Lightweight and transparent.** Pure Python + Shell. No heavy runtime, no hidden behavior.
10. **Automatically manage dependencies.** Support for software packages with dependencies, using reference counting and automatic dependency management, with no need to handle dependencies manually.

## 🌊 Install LinuxWave

In the terminal, run:

```
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh | /bin/bash
```

(When it finishes, the installer prints the exact command that makes `wave` available in the current terminal.)

**We recommend reading the handbook after installing. [Read it here](Foreword/Foreword-en.md).**

**Requirements: Python (3.14 and above), patchelf (for dependency library relocation).**

### Unattended install

For scripts and batch use, the installer takes flags so it never waits for input:

```
# script already on disk
bash install.sh --ci

# straight from the repository
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh | /bin/bash -s -- --ci
```

`--ci` answers the directory menu and the agreement automatically. (This
is the **installer's** flag; `wave` has its own `-s / --silent`, which prints nothing
at all — see *Scripting* below.) It
needs passwordless sudo, or root, when the chosen directory requires privilege.
Without `--dir-option`, it takes the recommended menu entry `1`
(`/home/linuxwave/.linuxwave`, the shared install) and prints which default it
used, instead of reading a terminal that may not exist.
`--dir-option=N` picks menu entry `N` (1-5); for the custom entry, append the path
after `=`, as in `--dir-option=5=/opt/mylw`, or just pass the path on its own, as in
`--dir-option=~/mylw`. Run `install.sh --help` for the list.

> **About this command.** The installer is streamed directly into `/bin/bash`, so
> nothing is saved to disk first. Please run it on a reliable network, and avoid
> pressing `Ctrl-C` while it is working: an interrupted stream stops the install
> partway. If that happens, simply run the same command again.
>
> **Please use this form as written.** Do not rewrite it as
> `/bin/bash -c "$(curl …)"`: that packs the entire script into a single
> command-line argument, and Linux refuses any single argument longer than
> 131 071 bytes (`Argument list too long`) — this installer is already close to
> that size. Do not pipe it into `sudo bash` either: `sudo` resets the environment
> (including `PATH` and proxy variables) and bypasses the installer's own
> privilege handling. To pass options, use `/bin/bash -s -- <options>`.

`uninstall.sh` is scriptable in the same way: `--force` skips both confirmations
and keeps the `linuxwave` account, while `--remove-user` also deletes that account.
Add both for a fully unattended removal.

> **Without `--force`, the uninstaller needs a terminal.** It reads the
> confirmation from `/dev/tty` and **stops** when there is none, instead of
> treating a closed stdin as "yes" - deleting is not reversible. Scripts and CI
> must say `--force` explicitly.

## 🌊 Download Directory 
Installed binaries are stored in (options):    
```
1. /home/linuxwave/.linuxwave (shared, all users) [recommended]
2. ~/.local/linuxwave
3. /opt/linuxwave
4. /usr/local/linuxwave
5. Custom
```
Config file is stored in (a system-level install always takes priority):
```
1. /etc/linuxwave_config          system-level install (needs sudo)
2. ~/.config/linuxwave_config     user-level install (no sudo)
```
A shared install (option 1, recommended) always uses `/etc/linuxwave_config`, so every user
on the machine resolves the same install. It needs `patchelf`, Python 3.14+ and
`sudo` once; the `linuxwave` account is created automatically if missing.

> **A shared install is group-based (Linuxbrew style).** The tree belongs to the
> `linuxwave` group, and whoever runs the installer joins it, so packages install
> as yourself — no `sudo`, no full path:
> ```
> wave install <package>
> ```
> Group membership only applies to a new login, so log out and back in (or run
> `newgrp linuxwave`) once before the first install. Upgrading an older shared
> install does the same thing — `wave selfupdate` hands the tree to the group and
> adds you to it — so re-login after that too, if it is the first time. If it is
> still unwritable after a re-login, a `systemd --user` manager started at your
> first login is holding the old credentials: run `systemctl --user exit`, then
> log in again (a reboot does the same). More
> users: `sudo usermod -aG linuxwave <user>` (they re-login as well). Group
> members can write the whole tree, `lib/wave` included. `wave selfupdate` still
> needs `sudo`: it rewrites `/etc/linuxwave_config`, which is root-owned. A user
> who is not in the group gets a working `sudo` command in the error message —
> `sudo wave install …` cannot work, because `sudo` searches its own `PATH`.

> **A non-shared system install is owned by `root:root`, mode 755.** That covers
> options 2 and 3 (`/opt/linuxwave`, `/usr/local/linuxwave`) and any custom
> directory outside your home. Everyone can still run what is installed, but
> installing, upgrading or removing packages needs `sudo` — and `sudo` searches
> its own `PATH`, so give the full path:
> ```
> sudo /opt/linuxwave/lib/wave install <package>
> ```
> The tree must not be writable by a normal user: its binaries sit on the system
> `PATH`, so anyone who can replace `links/<name>` may get it executed by another
> account, or by root. If you want plain `wave install` without `sudo`, use the
> shared install (option 1, recommended).

## 🌊 Scripting

`wave` speaks the same dialect as `curl` when you need its output to stay out of
the way:

```bash
wave install jq -s          # print nothing; the exit code is the only signal
wave install jq -sS         # same, but keep the errors (no 🌊 prefix, so grep works)
```

`-s` only applies to commands that have progress to quiet — `install`, `upgrade`,
`uninstall`, `link`, `unlink`, `selfupdate`. Giving it to a read-only command
(`list`, `search`, `info`, `linkquery`, `mirror`) is an error rather than a silent
no-op: printing is what those commands are for. `-s` beats `-v`, and both may be
combined with other short flags (`-sX`, `-CsX`).

Prompts are skipped rather than left waiting: with `-s`, a "retry the download?"
question is answered "no" and a "which version?" question cancels, so an
unattended script never hangs.

## Uninstall LinuxWave

To completely remove LinuxWave from your system, run the following command in your terminal:

```
curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/uninstall.sh | /bin/bash
```

## 🌊 Run Packages
To run a package, use its versioned name:
```
{package_name}@{version}
```
Or create an unversioned shortcut once with `wave link {package_name}`, then just run:
```
{package_name}
```

## 🌊 Symlink Management
Once a versionless link exists, LinuxWave keeps it pointing at the right version on its own:

1. If the highest version is uninstalled, the versionless link moves to the highest version that remains, and the uninstalled version's own link goes with it.
2. An install re-points the versionless link at the version it just installed; add `--unlink` to that install to skip this.
3. If a package has no versions left at all, the versionless link is removed.
4. A versioned name is always callable, whether or not a versionless link exists.

A manual `wave unlink {package_name}` is remembered: a later uninstall will not re-create the link for that package.

## 🌊 Command Reference

```
Usage:
  wave <command> [package] [flags]

Commands:
  install     Install a package (latest version)
  upgrade     Install a package at the latest version
  reinstall   Reinstall the version(s) already installed
  transfer    Make installed packages independent of the install directory
  uninstall   Uninstall a package
  list        List installed packages
  search      Search for a package in the index
  info        Display detailed information about a package
  selfupdate  Update LinuxWave itself to the latest version
  link        Link installed packages without a version number
  unlink      Remove those unversioned links
  linkquery   Show which version an unversioned link points to
  mirror      Show which addresses packages are fetched from
  basedir     Print LinuxWave's install root (the base_dir in config.json)
  doctor      Check the install tree for problems (read-only)
  latest      Show which packages have a newer version available
  shellenv    Print the shell code that puts LinuxWave on your PATH
  manual      Show the full manual (same text as man and info)

Flags:
  -h, --help              Show help for any command
  -V, --version           Print version information
  -v, --verbose           Enable verbose output (show detailed logs)

Global Flags (can be used with any command):
  -C, --continue          Resume interrupted downloads (like curl -C -)
      --proxy string      Specify an HTTP/HTTPS proxy (e.g., http://127.0.0.1:8080)
      --skip-ssl          Skip SSL certificate verification (insecure)
      --limit-rate string Limit download speed (e.g., 200K, 1M, 5M)
      --ver string        Install a specific version of the package

Special Flags:
wave install <pkgname>@<version>   Download certain version(s) of a package
    --no-link                      Leave the unversioned link alone (install / uninstall; the old name --unlink works too)
    --all, -a                      Apply to every installed package (upgrade / link / unlink / linkquery)

Unversioned Links:
wave link <name>                   Link a package to its highest installed version
wave linkquery <name>              Show what <name> is linked to (e.g. 🌊 ffmpeg@9.0)
wave unlink <name>                 Remove that link

Shell setup:
wave shellenv                      Print the code that puts wave on your PATH (for eval)
```

Uninstalling a version re-points the link to the next highest one, and removes the link
when no version is left. `uninstall --unlink` keeps the link as-is, and **refuses to run**
when that would leave the link pointing at the version you are removing.
## 🌊 Demo Pictures

<p align="center">
  <img src="images/demo1.png" alt="demo1" width="80%" style="max-width: 720px;">
</p>

## 🌊 Supported Packages
(Listed in alphabetical order)

```

7zz              by Igor Pavlov
act              by nektos
actionlint       by rhysd
age              by FiloSottile
atuin            by atuinsh
bat              by David Peter
btm              by Clement Tsang
btop             by Aristocratos
chezmoi          by twpayne
circleci         by CircleCI
cloudflared      by cloudflare
columbula        by Sha0huaZhang
cosign           by Sigstore
delta            by dandavison
difft            by Wilfred Hughes
direnv           by direnv
docker-compose   by Docker
doggo            by mr-karan
duckdb           by duckdb
dust             by bootandy
eza              by Christina Sørensen and the eza community
fd               by David Peter
ffmpeg           by FFmpeg Team
flyctl           by superfly
fx               by antonmedv
fzf              by Junegunn Choi
gh               by cli
git-lfs          by git-lfs
gitleaks         by gitleaks
glow             by charmbracelet
golangci-lint    by golangci
gping            by orf
grpcurl          by fullstorydev
gwget            by GNU Project
hadolint         by Hadolint
htop             by Hisham Muhammad and the htop team
hyperfine        by sharkdp
ipsw             by blacktop
jj               by Jujutsu contributors
jless            by Paul Julius Martinez
jq               by Stephen Dolan, Nicolas Williams, William Langford, Owen Ou, itchyny, Mattias Wadman, Emanuele Torre, Asaf Meizner, avid Korczynski, et al.
just             by Casey Rodarmor
k9s              by derailed
kind             by Kubernetes SIG Testing
kubecolor        by kubecolor
kubeconform      by yannh
kubectx          by ahmetb
kustomize        by Kubernetes SIG CLI
lazydocker       by Jesse Duffield
lazygit          by jesseduffield
ldid             by Jay Freeman (saurik) / Procursus Team
lefthook         by Evil Martians
linuxwave        by Orhun Parmaksız
lsd              by Abin Simon
mise             by jdx
mkcert           by FiloSottile
ncdu             by Yoran Heling
nvim             by neovim
ollama           by ollama
palera1n         by palera1n Team
pandoc           by John MacFarlane
rclone           by rclone
restic           by restic
rg               by Andrew Gallant
robinsing        by Sha0huaZhang
ruff             by astral-sh
scc              by Ben Boyter
shellcheck       by koalaman
shfmt            by mvdan
sk               by skim-rs
sops             by getsops
spf              by yorukot
starship         by starship
stern            by stern
syncthing        by Syncthing contributors
taskwarrior-tui  by kdheepak
tldr             by tealdeer-rs
tmux             by Nicholas Marriott and contributors
tofu             by opentofu
tree             by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro
trivy            by aquasecurity
trollrestore     by JJTech (@JJTech0130)
ty               by Astral
typst            by typst
uv               by astral-sh
vhs              by charmbracelet
watchexec        by Watchexec contributors
websocat         by vi
xh               by ducaale
yazi             by sxyazi
yq               by Mike Farah
yt-dlp           by yt-dlp
zellij           by zellij-org
zoxide           by Ajeet D'Souza
```
## 🌊 License

This project is licensed under the **Apache License 2.0** - see the [LICENSE](LICENSE) file for the full text, and [NOTICE](NOTICE) for the attribution note. Packages that LinuxWave installs keep their own licenses.

License by release:

| Versions | License |
| :--- | :--- |
| `1.0.0` – `4.5.2` | MIT |
| `4.6.0` and later | Apache License 2.0 |

Everything up to and including `4.5.2` was published under the MIT License and stays under it:
nothing is retroactively relicensed. `4.6.0` is where the Apache-2.0 terms begin, which is also
why that release asks you to accept the agreement again.

## 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)


