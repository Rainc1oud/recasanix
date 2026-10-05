# T-UI — log in through the real web UI in a headless Chromium and stay logged in. This is the check
# that catches integration breaks between the pinned UI and the backend services (auth header format,
# routes the UI insists on, services rejecting what the gateway forwards), which API checks made from
# inside the machine miss: the services skip auth for loopback clients, a browser is not loopback.
{ pkgs, modules }:
let
  python = pkgs.python3.withPackages (ps: [ ps.playwright ]);
  script = ./ui-login.py;
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-ui-login";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import os
    import subprocess

    machine.start()
    for unit in [
        "casaos-gateway.service",
        "casaos-message-bus.service",
        "casaos.service",
        "casaos-user-service.service",
        "casaos-app-management.service",
    ]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(80)
    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")

    # the browser runs on the test driver and reaches the machine through a forwarded port
    machine.forward_port(host_port=8090, guest_port=80)
    env = dict(
        os.environ,
        HOME="/tmp",
        PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}",
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="true",
        FONTCONFIG_FILE="${fonts}",
    )
    result = subprocess.run(
        ["${python}/bin/python", "${script}", "http://localhost:8090", "admin", "recasanix-admin-pass-1"],
        env=env, capture_output=True, text=True, timeout=300,
    )
    print(result.stdout)
    print(result.stderr[-3000:])
    assert result.returncode == 0, "UI login check failed (output above)"
  '';
}
