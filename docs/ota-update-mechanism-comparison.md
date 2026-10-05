# NAS Appliance OS — Update Mechanism Comparison

## Context

CasaOS (candidate app-management layer) is effectively unmaintained (no updates since Dec 2024) and its fork ZimaOS carries multiple unauthenticated RCE-class CVEs. This reduces trust in relying on upstream live infrastructure (app store, update channel) and motivates taking the OS image + update pipeline under our own control via a full-image, OTA-updatable design rather than a mutable, package-manager-updated system.

## Options Evaluated

1. **NixOS build + own flake/binary cache as the update channel** — device runs a resident Nix daemon; updates are `nixos-rebuild`-style pulls against a private flake ref + substituter.
2. **NixOS build + RAUC** (optionally sealed with dm-verity) — Nix builds the image; RAUC handles signed A/B slot-swap delivery and delta transport (block-hash or casync).
3. **NixOS build + systemd-repart/systemd-sysupdate** — native systemd A/B tooling; no Nix runtime needed on-device.
4. **mkosi (Debian) + RAUC** — declarative Debian image spec, RAUC for transport.
5. **Buildroot + RAUC** — used by ZimaOS itself; Kconfig-declarative, imperative `.mk` build rules.
6. **Yocto + RAUC** — most industry-standard embedded path; steepest learning curve.
7. **TrueNAS SCALE model** — ZFS boot environments, dpkg disabled, read-only root via mount flag (not cryptographically enforced).
8. **Plain Debian/OMV, apt-managed** — baseline, no atomicity.

## Technical Rating (1–5, merit-only; familiarity/adoption excluded)

| Approach | Hermeticity | Diff efficiency | Runtime integrity | Rollback atomicity | On-device attack surface | Declarativeness |
|---|---|---|---|---|---|---|
| Nix flake + own binary cache | 5 | 5 (semantic, per-derivation) | 2 | 3 (generations, not atomic slot-swap) | 2 (full Nix daemon/evaluator resident) | 5 |
| **NixOS build + RAUC** | 5 | 4 (4KiB block-hash or casync CDC) | 5 (dm-verity, kernel-enforced) | 5 (atomic A/B slot swap) | 4 (small, single-purpose daemon) | 5 (build) / 3 (manifest) |
| NixOS build + systemd-repart/sysupdate | 5 | 1 (no native delta — whole-partition only) | 4 | 5 (atomic A/B) | 4 | 5 |
| mkosi (Debian) + RAUC | 3 | 4 | 5 | 5 | 4 | 4 |
| Buildroot + RAUC | 3 | 4 | 5 | 5 | 4 | 3 |
| Yocto + RAUC | 3 | 4 | 5 | 5 | 4 | 3 |
| TrueNAS SCALE (ZFS BE, dpkg disabled) | 2 | 1 (no OTA delta) | 1 (mount flag, not verity) | 4 | 2 | 1 |
| Plain Debian/OMV, apt | 2 | 1 | 1 | 1 | 1 | 1 |

## Key Findings

- **Diff efficiency vs. runtime integrity is the central tension.** Nix's content-addressed store gives the theoretically optimal diff (only changed derivations transfer), but a resident Nix daemon with root privileges is a larger on-device trusted-computing-base, and Nix verifies integrity only at fetch time — not continuously at read time the way dm-verity does.
- **`systemd-sysupdate` has no native delta support.** Confirmed via open upstream issues (systemd#28227, #33351) — it downloads whole partitions/files by design. KDE Linux hit this gap and built a custom `desync`-based bridging daemon as a stopgap; no turnkey solution exists upstream yet.
- **RAUC has native delta support** (block-hash adaptive updates, fixed 4KiB, or casync/desync integration for content-defined chunking) and dm-verity-backed atomic A/B rollback — the most mature, production-proven mechanism (notably used for Steam Deck updates).
- **Winner on pure technical merit: NixOS build + RAUC**, specifically the *hybrid* form — Nix-built image, dm-verity-sealed, delivered/applied via RAUC's atomic A/B mechanism. This is the only option that doesn't force a trade-off between build-time hermeticity and runtime-integrity/attack-surface — no existing reference implementation combines all three (Nix + verity + RAUC), so this is novel integration work, not adaptation of a template.
- Buildroot/Yocto/mkosi + RAUC all match RAUC's integrity/atomicity properties but lag Nix on build hermeticity (apt/make-based builds are not pure functions of a lockfile).
- TrueNAS SCALE's model (ZFS boot environments, dpkg disabled) provides real, battle-tested rollback atomicity but no cryptographic runtime integrity and no OTA delta mechanism — closer to a package-manager story than an image-OTA story.
