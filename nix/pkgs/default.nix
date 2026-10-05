# Overlay assembling every ReCasaOS component (none of them are in nixpkgs).
{ components, exclusions }:
final: _prev:
let
  inherit (final) callPackage;
  mkCasaosGo = callPackage ./mk-casaos-go.nix { inherit exclusions; };
  goService =
    path: name:
    callPackage path {
      inherit mkCasaosGo components;
      inherit (components.${name}) src;
    };
in
{
  oapi-codegen-v1 = callPackage ./oapi-codegen-v1 { };
  casaos = callPackage ./recasaos {
    inherit mkCasaosGo components;
    inherit (components.recasaos) src;
  };
  casaos-ui = callPackage ./casaos-ui {
    inherit components;
    inherit (components.casaos-ui) src;
  };
  casaos-sysroot = callPackage ./casaos-sysroot { };
  # ReCasaNix's own code (services/), not an upstream component.
  recasanix-storage = callPackage ./recasanix-storage { };
  casaos-gateway = goService ./recasaos-gateway "recasaos-gateway";
  casaos-message-bus = goService ./recasaos-message-bus "recasaos-message-bus";
  casaos-user-service = goService ./recasaos-user-service "recasaos-user-service";
  casaos-app-management = goService ./recasaos-app-management "recasaos-app-management";
}
