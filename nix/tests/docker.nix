# T5 (part 1, task 3.3) — Docker on the data pool: the appliance boots clean without a pool and without
# Docker running; once a pool exists Docker starts with its data root on it (overlay2), can run a
# container, and everything is still there after a reboot. The image is built with Nix and loaded, since
# the test has no network (`hello-world` from a registry is not available).
{ pkgs, modules }:
let
  image = pkgs.dockerTools.buildLayeredImage {
    name = "recasanix-hello";
    tag = "latest";
    config.Cmd = [ "${pkgs.hello}/bin/hello" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "recasanix-docker";

  nodes.machine = {
    imports = [
      modules.appliance
      modules.storage
      modules.docker
    ];
    recasanix.docker.enable = true;
    recasanix.appliance.admin.initialHashedPassword = "!";
    virtualisation.emptyDiskImages = [ 1024 ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    pool = "/var/lib/recasanix/data"

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("no pool: clean boot, Docker skipped rather than failed"):
        machine.succeed("systemctl is-system-running --wait | grep -qx running")
        machine.fail("systemctl is-active --quiet docker.service")
        machine.fail("systemctl is-failed --quiet docker.service")
        machine.succeed("test -d /DATA")  # the data root exists on the root filesystem
        machine.fail("findmnt -M /DATA")

    with subtest("a pool created at runtime brings Docker up on it"):
        # what the storage layer will do: create the pool, its DATA directory, then start things
        machine.succeed("mkfs.btrfs -q -L recasanix-data /dev/vdb && udevadm settle")
        machine.succeed(f"mkdir -p {pool}/DATA")
        machine.succeed("systemctl start DATA.mount docker.service")
        machine.succeed("findmnt -M /DATA -t btrfs")
        assert machine.succeed("docker info --format '{{.DockerRootDir}}'").strip() == f"{pool}/docker"
        assert machine.succeed("docker info --format '{{.Driver}}'").strip() == "overlay2"

    with subtest("a container runs; its data is on the pool, not on the root filesystem"):
        machine.succeed("docker load < ${image}")
        machine.succeed("docker run --rm recasanix-hello:latest | grep -q 'Hello, world'")
        machine.succeed(f"test -d {pool}/docker/overlay2")
        machine.fail("test -e /var/lib/docker")
        # app data written under /DATA lands on the pool too
        machine.succeed("mkdir -p /DATA/AppData/demo && echo data > /DATA/AppData/demo/file")
        machine.succeed(f"grep -qx data {pool}/DATA/AppData/demo/file")

    with subtest("after a reboot the pool, /DATA and Docker come back by themselves"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("docker.service")
        machine.succeed("findmnt -M /DATA -t btrfs")
        machine.succeed("docker image inspect recasanix-hello:latest >/dev/null")
        machine.succeed("grep -qx data /DATA/AppData/demo/file")
        machine.succeed("systemctl is-system-running --wait | grep -qx running")
  '';
}
