# Every flake check. `nix flake check` is the single entry point (AGENTS.md §2).
{
  lib,
  pkgs,
  components,
  exclusions,
  nixos,
  modules,
  image,
}:
(import ./unit.nix { inherit lib pkgs; })
// {
  pin-drift = import ./pin-drift.nix { inherit lib pkgs components; };
  lint = import ./lint.nix { inherit lib pkgs; };
  no-host-management = import ./no-host-management.nix {
    inherit
      lib
      pkgs
      exclusions
      nixos
      ;
  };
  storage = import ./storage.nix { inherit pkgs; };
  recasaos-boot = import ./recasaos-boot.nix { inherit pkgs modules; };
  ui-login = import ./ui-login.nix { inherit pkgs modules; };
  state-persistence = import ./state-persistence.nix { inherit pkgs modules; };
  docker = import ./docker.nix { inherit pkgs modules; };
  app-lifecycle = import ./app-lifecycle.nix { inherit pkgs modules; };
  storage-manager = import ./storage-manager.nix { inherit pkgs modules; };
  image-boots = import ./image-boots.nix { inherit pkgs image; };
}
