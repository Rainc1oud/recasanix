# ReCasaNix

ReCasaNix is a NixOS spin of [ReCasaOS](https://github.com/EdmundFu-233/ReCasaOS): a semi-embedded,
image-based OS for a NAS appliance, built reproducibly from a Nix flake.

## Status

> :warning: Pre-alpha/development. Currently this is a PoC on how to leverage (Re)CasaOS
> prior art while gaining the unique advantages (reproducibility, stability, maintainability)
> that NixOS-base offers in comparison with Debian-base.

## Origin

- [CasaOS](https://github.com/IceWhaleTech/CasaOS) is a web UI and app/device management layer for
  home servers. It has been neglected upstream for a while (no releases since December 2024), while
  it carries RCE-class vulnerabilities.
- [ReCasaOS](https://github.com/EdmundFu-233/ReCasaOS) forked CasaOS to keep it security-maintained.
- ReCasaNix packages ReCasaOS for NixOS and turns it into an immutable appliance image. It is **not**
  a fork: the intention is to track ReCasaOS upstream, pinned to the component set upstream itself
  validates (`release/components.lock.json`), and to carry only the small patches an image-based,
  Nix-managed host needs (see [docs/upstream-exclusions.md](./docs/upstream-exclusions.md)). The
  (Re)CasaOS components are deliberately not rebranded.

## Goals

Build a semi-embedded OS that provides a solid base image for a NAS device, without re-inventing the
wheel on its main features. It integrates existing open-source solutions:

- web-based UI and app store (ReCasaOS)
- a maintenance-friendly, robust and reproducible image build pipeline (NixOS)

### Prominent features

- NixOS-based image for a solid, vendor-managed, immutable base
- Image-based updates (A/B partition layout; RAUC is the intended update mechanism)
- Integrates [ReCasaOS](https://github.com/EdmundFu-233/ReCasaOS) for the UI, including the CasaOS
  App Store
- btrfs data pool, created at runtime from the UI

### Technical notes

- User configuration (mutable via the CasaOS UI) is kept apart from the immutable NixOS base: Nix
  owns the cold layer, users/shares/pools/apps are hot state (see [AGENTS.md](./AGENTS.md) §2).
- Every ReCasaOS component is built from source as a flake-pinned derivation (`buildGoModule`,
  pnpm), then integrated into the image.
- `nixpkgs` comes from https://flakehub.com/f/NixOS/nixpkgs/0.1.

### Target hardware

A custom developed NAS: an Intel N200-based x86_64 board booting from eMMC or NVMe, with NVMe/SATA data
disks. Until hardware is available, everything is demonstrated in a VM and under QEMU emulation.

## Development strategy

This flake declares:

- a runnable VM output with the complete OS prototype
- an image output for the prototype, deployable on the NAS hardware

## Testing

Quick start for bringing up the VM, running the tests, building the hardware image, testing it under
emulation and flashing it: see [TESTING.md](./TESTING.md).

## References

### Update mechanism

See [Update Mechanism](./docs/ota-update-mechanism-comparison.md).
