# T8 — statix + deadnix + nixfmt over the tree, as one check derivation.
{ lib, pkgs }:
let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.fileFilter (f: f.hasExt "nix") ../..;
  };
in
pkgs.runCommand "lint"
  {
    nativeBuildInputs = with pkgs; [
      statix
      deadnix
      nixfmt
    ];
  }
  ''
    cd ${src}
    files="$(find . -name '*.nix' | sort)"
    echo "== nixfmt --check"; nixfmt --check $files
    echo "== statix check";   statix check .
    echo "== deadnix --fail"; deadnix --fail .
    touch $out
  ''
