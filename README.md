# reticulum-flake playbook

How to deploy a NomadNet/Reticulum node as a NixOS Incus container using this
flake, and every non-obvious problem hit building the first one
(`nomadnet-ct` on x11-4, 2026-07-07) with the actual fix for each.

## What this flake provides

- `packages.x86_64-linux.reticulum-stack` — `rns`==1.1.8, `nomadnet`==0.9.8,
  `lxmf`==0.9.4, packaged as a real Nix derivation via **`uv2nix`** (not
  `poetry2nix` — see below for why), exposing `rnsd` and `nomadnet`
  executables.
- `nixosModules.default` — a NixOS module (`module.nix`) wiring that package
  into two `systemd.services` (`rnsd`, `nomadnet`) with the reliability
  pattern validated on vm156/vm158 (real Debian VMs, see
  `nomadnet-server-playbook.md` in the `nomadnet-pages` repo for that
  original investigation) translated into native NixOS options.

## Why uv2nix, not poetry2nix

`poetry2nix` was the original choice but is unmaintained (its GitHub
`master` hadn't moved since 2025-04-03 as of this writing) and has an
unfixable bug: its wheel-selection code hard-errors on an unrecognized iOS
platform tag (`ios_13_0_arm64_iphoneos`) that `cryptography`'s newer PyPI
releases publish. Pinning `cryptography` to an older version didn't help
(the crash happens during a metadata-scan pass that isn't strictly
version-gated), and overriding it to use nixpkgs' own build didn't help
either — the crash persisted at yet another version number, suggesting the
bug is baked into how `mkPoetryEnv` computes its dependency closure, not
something reachable by a targeted override. `uv2nix` (actively maintained,
`github:pyproject-nix/uv2nix`) built the identical dependency set cleanly on
the first real attempt.

`pyproject.toml` for this kind of "just pin some third-party packages, no
real code of our own" use case deliberately has **no `[build-system]`
section** — that makes it a virtual/non-buildable root project, which is
uv's supported pattern for pure dependency-locking.

## Bootstrapping a new container from this flake

1. `incus launch images:nixos/26.05 <name>` — use the NixOS version matching
   the host, not a generic Debian/Ubuntu image. Incus's official image
   server carries ready-made NixOS container images.
2. Give the container its own small config directory on the **host**, e.g.
   `/etc/nixos-<name>/` with a `flake.nix` (referencing this flake as a
   `path:` input) and `configuration.nix` (hostname, networking, imports
   `nixosModules.default`). Keep this separate from the host's own
   `/etc/nixos` — don't bind-mount the host's real `/etc/nixos` into the
   container, since that exposes host secrets (e.g. the root/user password
   hash file) into the container's filesystem namespace unnecessarily.
3. Bind-mount that host directory into the container's `/etc/nixos`, **and**
   bind-mount this flake's own source directory into the container at the
   *same absolute path* it lives at on the host (e.g.
   `/home/user/reticulum-flake` → `/home/user/reticulum-flake`) — the
   container has its own separate filesystem, so a `path:` input pointing at
   a host path needs that path to actually exist inside the container too:
   ```
   incus config device add <name> nixos-config disk source=/etc/nixos-<name> path=/etc/nixos
   incus config device add <name> reticulum-flake disk source=/home/user/reticulum-flake path=/home/user/reticulum-flake
   ```
4. **Both bind-mounted devices need `shift=true`.** Unprivileged Incus
   containers remap UIDs, so without this, the container's root doesn't
   correspond to the host's root for the mounted directory and can't write
   `flake.lock`:
   ```
   incus config device set <name> nixos-config shift=true
   incus config device set <name> reticulum-flake shift=true
   ```
5. First build needs sandboxing off — unprivileged containers can't create
   the nested kernel namespaces Nix's build sandbox wants:
   ```
   incus exec <name> -- nixos-rebuild switch --flake /etc/nixos#<name> --option sandbox false
   ```
   Add `nix.settings.sandbox = false;` to `configuration.nix` so this is
   permanent and future rebuilds don't need the flag.
6. **Fix `/sbin/init` immediately after the first switch, before rebooting.**
   This is the single biggest gotcha found today: the official
   `images:nixos/*` Incus image ships `/sbin/init` as a *static* symlink
   baked in at image-build time, pointing at that original image's own
   store path. `nixos-rebuild switch` correctly updates
   `/nix/var/nix/profiles/system` and the *live* running system, but a real
   reboot re-execs the stale baked-in `/sbin/init` and silently reverts to
   the original generation — services vanish, `systemctl status` says "Unit
   could not be found," and it looks like the switch never happened at all,
   even though it did. Confirmed this exact failure mode with a real
   `incus restart`. Fix:
   ```
   incus exec <name> -- ln -sfn /nix/var/nix/profiles/system/init /sbin/init
   ```
   This makes `/sbin/init` dynamically track whatever `nixos-rebuild`
   currently has active, so future switches persist across reboots without
   re-applying the symlink each time. **Verify with an actual reboot**, not
   just `systemctl restart` on individual services — that's what exposed
   this bug in the first place; a live `nixos-rebuild switch` alone looks
   completely fine.
7. `incus config set <name> boot.autostart true` so the container comes back
   up automatically when the host itself reboots.

## Reticulum interface config

`rnsd`/`nomadnet` run as a dedicated `nomadnet` system user (home
`/var/lib/nomadnet`), not the interactive `user` account — a deliberate
NixOS-convention choice (least-privilege dedicated service account) that
differs from the vm156/158 pattern, where the service ran as the same
account used for SSH login. Practical implications:

- Reticulum config lives at `/var/lib/nomadnet/.reticulum/config`, NomadNet's
  own at `/var/lib/nomadnet/.nomadnetwork/config`, pages at
  `/var/lib/nomadnet/.nomadnetwork/storage/pages/`.
- Deploy files into the container via `incus file push <local> <ct>/<path>`,
  then `incus exec <ct> -- chown nomadnet:nomadnet <path>` (the container's
  own root can write anywhere in its own filesystem — no UID-shift concerns
  here, that only applies to the *bind-mounted host directories*).
- Check real interface/connectivity status directly rather than trusting
  `journalctl` — `rnsd` didn't appear to log connection events to the
  journal here the way it did on vm156/158's plain-Debian setup, but
  `su - nomadnet -c rnstatus` shows live interface state (Up/Down, traffic
  counters, reachable peer counts) regardless. Growing file sizes/mtimes on
  `~/.reticulum/storage/destination_table` and `known_destinations` are also
  a reliable signal that announces are actively being received.

## Accessing the running node

Because the service runs as the dedicated `nomadnet` user, plain
`ssh user@<ip>` + `tmux attach -t nomadnet` (the vm156/158 pattern) does
**not** work here — `user`'s tmux socket is a different one. From any LAN
machine:
```
ssh user@<container-ip>
sudo -u nomadnet tmux attach -t nomadnet
```
`user` has passwordless `wheel` sudo in the container config, so no
password prompt. Confirmed working from a separate LAN machine (t480a),
not just via `incus exec` from the Incus host itself.

## Notes

- Developed and validated locally on x11-4 first, then pushed to the
  household NAS (a password-authenticated, chrooted SFTP account — kept
  separate from this GitHub mirror on purpose) as the actual source of
  truth. This GitHub repo is a public backup/reference copy, not where
  changes originate.
- `rnsd`'s own Reticulum interfaces were copied verbatim from vm156
  (`~/.reticulum/config` `[interfaces]` section) — `enable_transport`
  deliberately left at this container's own default (`False`) rather than
  also copying vm156's `True`, since only the interfaces were asked for and
  transport mode has real traffic/resource implications worth a deliberate
  choice rather than inheriting silently.
