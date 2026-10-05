# casaos-sysroot — one merged share/casaos-sysroot tree of all six components (task 1.7), so the
# NixOS module has a single input. buildEnv fails on a file collision (ignoreCollisions = false), so
# two components can never silently shadow each other's files.
{
  buildEnv,
  casaos,
  casaos-gateway,
  casaos-message-bus,
  casaos-user-service,
  casaos-app-management,
  casaos-ui,
}:
buildEnv {
  name = "casaos-sysroot";
  paths = [
    casaos
    casaos-gateway
    casaos-message-bus
    casaos-user-service
    casaos-app-management
    casaos-ui
  ];
  pathsToLink = [ "/share/casaos-sysroot" ];
  ignoreCollisions = false;
}
