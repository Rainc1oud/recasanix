# T5 (part 2) — the app lifecycle through AppManagement's own API: log in, install a compose app whose
# image is preloaded (no network in the test, no public app store), see its container running with its
# data on the data pool, stop it, uninstall it. Together with docker.nix this is the end-to-end check that
# the appliance can run apps at all.
{ pkgs, modules }:
let
  image = pkgs.dockerTools.buildLayeredImage {
    name = "recasanix-sleeper";
    tag = "latest";
    config.Cmd = [
      "${pkgs.coreutils}/bin/sleep"
      "infinity"
    ];
  };

  compose = pkgs.writeText "docker-compose.yml" ''
    name: demo
    services:
      demo:
        image: recasanix-sleeper:latest
        pull_policy: never
        restart: unless-stopped
        network_mode: bridge
        volumes:
          - type: bind
            source: /DATA/AppData/demo/config
            target: /config
        x-casaos:
          ports: []
          volumes:
            - container: /config
              description:
                en_us: App configuration
    x-casaos:
      architectures:
        - amd64
      main: demo
      author: ReCasaNix tests
      category: Test
      description:
        en_us: A container that does nothing, to prove the lifecycle.
      developer: ReCasaNix
      icon: ""
      index: /
      port_map: "0"
      scheme: http
      tagline:
        en_us: Sleeps
      title:
        en_us: Demo
  '';
in
pkgs.testers.runNixOSTest {
  name = "recasanix-app-lifecycle";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.state
      modules.docker
      modules.recasaos
    ];
    services.recasaos.enable = true;
    recasanix = {
      docker.enable = true;
      state.enable = true;
      appliance.admin.initialHashedPassword = "!";
    };
    virtualisation.emptyDiskImages = [ 2048 ];
    virtualisation.memorySize = 3072;
  };

  testScript = ''
    import json
    pool = "/var/lib/recasanix/data"

    machine.start()
    for unit in ["casaos-gateway", "casaos-message-bus", "casaos", "casaos-user-service", "casaos-app-management"]:
        machine.wait_for_unit(unit + ".service")
    machine.wait_for_open_port(80)

    # the storage layer's job, done by hand: pool, its DATA directory, mounts, Docker — then the services
    # that pinned /DATA at startup are restarted so they see the pool
    machine.succeed("mkfs.btrfs -q -L recasanix-data /dev/vdb && udevadm settle")
    machine.succeed(f"mkdir -p {pool}/DATA")
    machine.succeed("systemctl start DATA.mount docker.service")
    machine.succeed("systemctl restart casaos.service casaos-app-management.service")
    machine.wait_for_unit("casaos-app-management.service")
    machine.succeed("docker load < ${image}")

    machine.succeed("printf 'admin\\nrecasanix-admin-pass-1\\n' | recasanix-user-admin bootstrap")
    machine.wait_for_unit("casaos-user-service.service")
    token = json.loads(machine.succeed(
        "curl -s -X POST -H 'Content-Type: application/json' "
        "-d '{\"username\":\"admin\",\"password\":\"recasanix-admin-pass-1\"}' http://localhost/v1/users/login"
    ))["data"]["token"]["access_token"]

    def api(method, path, extra="", body=None):
        data = f"--data-binary @{body}" if body else ""
        return machine.succeed(
            f"curl -s -X {method} -H 'Authorization: Bearer {token}' {extra} {data} 'http://localhost{path}'"
        )

    machine.succeed("cp ${compose} /tmp/demo.yml")
    machine.succeed("echo '\"stop\"' > /tmp/stop.json && echo '\"start\"' > /tmp/start.json")

    def running():
        return machine.succeed("docker ps --format '{{.Names}}'").split()

    with subtest("install a compose app"):
        out = json.loads(api("POST", "/v2/app_management/compose?dry_run=true", "-H 'Content-Type: application/yaml'", "/tmp/demo.yml"))
        assert "only validation" in out["message"], out
        out = json.loads(api("POST", "/v2/app_management/compose", "-H 'Content-Type: application/yaml'", "/tmp/demo.yml"))
        assert "installed asynchronously" in out["message"], out
        machine.wait_until_succeeds("docker ps --format '{{.Names}}' | grep -q demo", timeout=120)
        apps = json.loads(api("GET", "/v2/app_management/compose"))["data"]
        assert "demo" in apps, list(apps)

    with subtest("the app's data lives on the pool, not on the root filesystem"):
        machine.succeed(f"test -d {pool}/DATA/AppData/demo/config")
        machine.succeed("findmnt -M /DATA -t btrfs")

    with subtest("stop, start, uninstall"):
        api("PUT", "/v2/app_management/compose/demo/status", "-H 'Content-Type: application/json'", "/tmp/stop.json")
        machine.wait_until_succeeds("! docker ps --format '{{.Names}}' | grep -q demo", timeout=60)
        api("PUT", "/v2/app_management/compose/demo/status", "-H 'Content-Type: application/json'", "/tmp/start.json")
        machine.wait_until_succeeds("docker ps --format '{{.Names}}' | grep -q demo", timeout=60)
        api("DELETE", "/v2/app_management/compose/demo")
        machine.wait_until_succeeds("! docker ps -a --format '{{.Names}}' | grep -q demo", timeout=60)
        assert "demo" not in json.loads(api("GET", "/v2/app_management/compose"))["data"]
  '';
}
