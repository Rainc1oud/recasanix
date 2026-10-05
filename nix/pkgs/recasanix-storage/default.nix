# The storage manager behind the UI's storage widget: a small, read-only Go service that lists the
# machine's disks and volumes on the routes the UI already calls (source: services/recasanix-storage).
# It is ReCasaNix's own code — not an upstream component — and replaces CasaOS-LocalStorage, which
# ReCasaOS does not ship. See docs/storage-manager.md.
{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "recasanix-storage";
  version = "0.1.0";

  src = lib.cleanSource ../../../services/recasanix-storage;

  # `nix build .#recasanix-storage` with lib.fakeHash prints the real one after a dependency change.
  vendorHash = "sha256-vx1dLbx+bJWi8jVadLH3FCK+/qWz2kZk5AmwFIfxue8=";

  # No cgo: a static, self-contained binary.
  env.CGO_ENABLED = "0";
  ldflags = [
    "-s"
    "-w"
  ];

  # The unit tests run as a separate check (T1, `checks.*.unit-recasanix-storage`), like every other
  # component, so they cannot block an image build.
  doCheck = false;

  meta = {
    description = "Read-only storage manager for the ReCasaNix web UI (lists disks and volumes)";
    license = lib.licenses.agpl3Plus; # our own code; the intended licence for the glue (AGENTS.md §2)
    platforms = lib.platforms.linux;
    mainProgram = "recasanix-storage";
  };
}
