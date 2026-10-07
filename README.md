# 🌊 LinuxWave Data

The package index that LinuxWave reads at runtime: where every package and
dependency comes from, its `sha256`, and what it depends on.

> **Site notice**: the official website has moved to **[linuxwave.org](https://linuxwave.org)**.
> The old `linuxwave.macwave.org` now returns `404`. Install commands are unchanged, and an
> existing install only needs one `wave selfupdate` (`2.6.2` carries the change).

# 🌊 Official Website

[linuxwave.org](https://linuxwave.org)

# 🌊 What is this branch?

LinuxWave itself lives on `main`. This branch carries **data only** — the
installer and `wave selfupdate` never read it, but `wave install`,
`wave search` and `wave info` do, and they read it live (there is no local
cache to refresh).

# 🌊 Layout

```
pkg/pkginfo_{arch}/{name}/_{name}@common             bin_name / des / hom / lic / aut
pkg/pkginfo_{arch}/{name}/_{name}@{version}          url / sha256 / deps

surfboard/depsinfo_{arch}/{name}/_{name}@common      dep_name / des / hom / lic / aut
surfboard/depsinfo_{arch}/{name}/_{name}@{version}   url / sha256 / deps
```

`{arch}` is `amd64` (linux-64) or `arm64` (linux-aarch64).

- `url` must be `https://`.
- `sha256` is verified before anything is extracted.
- `deps` lists one `name@version` per line, written as a quoted multi-line
  list. A package without a `deps` field has no dependencies.

# 🌊 Install LinuxWave

In the terminal, run:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/LinuxWaveOrg/LinuxWave/HEAD/lib/install.sh)" && source ~/.zshrc
```

(If you are using bash instead of zsh, run `source ~/.bashrc`)

**Requirements: Python (3.14 and above), patchelf (for dependency library relocation).**

# 🌊 Supported Packages
(Listed in alphabetical order)

```
bat           by David Peter
btop          by Aristocratos
dust          by bootandy
eza           by Christina Sørensen and the eza community
fd            by David Peter
ffmpeg        by FFmpeg Team
fzf           by Junegunn Choi
htop          by Hisham Muhammad and the htop team
ipsw          by blacktop
jq            by Stephen Dolan, Nicolas Williams, et al.
ldid          by Jay Freeman (saurik) / Procursus Team
lsd           by Abin Simon
ncdu          by Yoran Heling
palera1n      by palera1n Team
pandoc        by John MacFarlane
rg            by Andrew Gallant
tmux          by Nicholas Marriott and contributors
trollrestore  by JJTech (@JJTech0130)
wget          by GNU Project
zoxide        by Ajeet D'Souza
```

# 🌊 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

# 🌊 Contact Us

Email：[hi@macwave.org](mailto:hi@macwave.org)
