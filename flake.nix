{
  description = "ReCasaNix — NixOS-based NAS appliance image (VM + hardware)";

  inputs = {
    # FlakeHub nixpkgs 0.1.* tracks nixpkgs-unstable (see README "Technical Notes").
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.tar.gz";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    # pre-commit hooks, installed by entering the dev shell (guards nix/hosts/admin-authorized-keys)
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # ReCasaOS components, plain (non-flake) inputs. Unpinned URLs; revs live in flake.lock and only
    # nix/pins/update.sh moves them (never a bare `nix flake update`: T7 fails).
    # - component with open upstream PRs: our fork's `recasanix-preview` = upstream pin + PRs merged
    #   (nix/pins/preview.json) → post-merge preview through the normal source mechanism
    # - other components: upstream, at the rev of the root's release/components.lock.json
    recasaos = {
      url = "github:ppenguin/ReCasaOS-EF/recasanix-preview";
      flake = false;
    };
    recasaos-gateway = {
      url = "github:EdmundFu-233/ReCasaOS-Gateway";
      flake = false;
    };
    recasaos-user-service = {
      url = "github:ppenguin/ReCasaOS-UserService-EF/recasanix-preview";
      flake = false;
    };
    recasaos-app-management = {
      url = "github:ppenguin/ReCasaOS-AppManagement-EF/recasanix-preview";
      flake = false;
    };
    recasaos-message-bus = {
      url = "github:ppenguin/ReCasaOS-MessageBus-EF/recasanix-preview";
      flake = false;
    };
    # UI: ReCasaOS-UI, maintained fork of IceWhaleTech/CasaOS-UI (AGENTS.md §2)
    casaos-ui = {
      url = "github:ppenguin/ReCasaOS-UI-EF/recasanix-preview";
      flake = false;
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      components = import ./nix/lib/components.nix {
        inherit lib;
        inherit inputs;
      };
      exclusions = import ./nix/lib/exclusions.nix { inherit lib; };

      # What every machine built from these modules needs besides them: the component overlay, and the
      # UI's unfree allowance (AGENTS.md §6).
      packageModules = [
        inputs.self.nixosModules.recasaos
        {
          nixpkgs.overlays = [ inputs.self.overlays.default ];
          nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "casaos-ui" ];
        }
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.git-hooks.flakeModule ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        # `nix eval .#lib.components` / `.#lib.exclusions`
        lib = { inherit components exclusions; };
        overlays.default = import ./nix/pkgs { inherit components exclusions; };

        nixosModules = {
          appliance = ./nix/modules/appliance.nix;
          storage = ./nix/modules/storage.nix;
          state = ./nix/modules/state.nix;
          docker = ./nix/modules/docker.nix;
          recasaos = ./nix/modules/recasaos.nix; # needs `overlays.default` and the UI's unfree allowance in pkgs
          image = ./nix/modules/image.nix;
          hardware-n200 = ./nix/modules/hardware-n200.nix;
        };

        nixosConfigurations = {
          recasanix-vm = nixpkgs.lib.nixosSystem {
            modules = [ ./nix/hosts/recasanix-vm.nix ] ++ packageModules;
          };
          recasanix-image = nixpkgs.lib.nixosSystem {
            modules = [ ./nix/hosts/recasanix-image.nix ] ++ packageModules;
          };
        };
      };

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          # Package set with the overlay; the UI is `unfree` (AGENTS.md §6), allow only it.
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
            config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "casaos-ui" ];
          };

          # Task 0.3: every component package, plus legacyPackages for exploration.
          legacyPackages = pkgs;

          packages =
            lib.getAttrs (builtins.attrNames (inputs.self.overlays.default { } { })) pkgs
            // {
              # docs/upstream-exclusions.md, rendered from nix/lib/exclusions.nix (checked by T9)
              exclusions-register = pkgs.writeText "upstream-exclusions.md" exclusions.register;
            }
            // lib.optionalAttrs (system == "x86_64-linux") {
              # Task 4.1: the runnable development VM.
              vm = pkgs.callPackage ./nix/vm-runner.nix {
                vm = inputs.self.nixosConfigurations.recasanix-vm.config.system.build.vm;
              };

              # Tasks 4.2/4.3: the flashable GPT disk image (a directory holding the .raw file).
              image = inputs.self.nixosConfigurations.recasanix-image.config.system.build.image;

              # `nix run .#emulate-image`: boots that image under QEMU/OVMF on a scratch copy.
              emulate-image = pkgs.callPackage ./nix/image-runner.nix {
                inherit (config.packages) image;
                sshKeys = builtins.length inputs.self.nixosConfigurations.recasanix-image.config.recasanix.appliance.admin.authorizedKeys;
              };
            };

          apps = lib.optionalAttrs (system == "x86_64-linux") {
            vm = {
              type = "app";
              program = lib.getExe config.packages.vm;
              meta.description = "Boot the ReCasaNix development VM (UI on localhost:8080)";
            };
            emulate-image = {
              type = "app";
              program = lib.getExe config.packages.emulate-image;
              meta.description = "Boot the custom NAS image under QEMU/OVMF (UI on localhost:8081, ssh on 2223)";
            };
          };

          # Phase 5 tests. The VM tests need KVM; they only make sense for the appliance architecture.
          checks = lib.optionalAttrs (system == "x86_64-linux") (
            import ./nix/tests {
              inherit
                lib
                pkgs
                components
                exclusions
                ;
              nixos = inputs.self.nixosConfigurations.recasanix-vm;
              inherit (config.packages) image;
              modules = inputs.self.nixosModules;
            }
          );

          formatter = pkgs.nixfmt-tree;

          # Your SSH key lives only in your working copy of nix/hosts/admin-authorized-keys (the
          # committed file is an empty template; Nix reads tracked files from the working copy). This
          # hook refuses a commit that would publish a key; pre-commit stashes unstaged changes first,
          # so it judges exactly what is being committed. Not a flake check: `nix flake check` sees the
          # working copy, where the key legitimately is — CI checks the committed file instead.
          pre-commit = {
            check.enable = false;
            settings.hooks.no-admin-keys = {
              enable = true;
              name = "no SSH keys committed in admin-authorized-keys";
              files = "^nix/hosts/admin-authorized-keys$";
              entry = toString (
                pkgs.writeShellScript "no-admin-keys" ''
                  for f; do
                    if ${pkgs.gnugrep}/bin/grep -qvE '^[[:space:]]*(#|$)' "$f"; then
                      echo "$f: SSH keys must not be committed — keep them in your working copy only:" >&2
                      echo "  git restore --staged $f" >&2
                      exit 1
                    fi
                  done
                ''
              );
            };
          };

          devShells.default = pkgs.mkShell {
            name = "recasanix-dev";
            # pre-commit + the hooks' tools, and its shellHook installing .git/hooks/pre-commit
            inputsFrom = [ config.pre-commit.devShell ];
            packages = with pkgs; [
              # Nix tooling
              nix-output-monitor
              nix-tree
              nix-prefetch-git
              nixfmt
              deadnix
              statix

              # scripting / inspection used by the development plan
              python3
              jq
              yq-go
              curl
              git

              # component toolchains (for reproducing upstream builds by hand)
              go_1_26
              gopls
              nodejs_22
              pnpm

              # image + VM work
              qemu_kvm
              OVMF.fd
              systemd # systemd-repart, systemd-dissect
              util-linux
              dosfstools
              e2fsprogs
              squashfsTools
              rauc
            ];

            shellHook = ''
              echo "ReCasaNix dev shell — see DEVELOPMENT.md for the task list."
            '';
          };
        };
    };
}
