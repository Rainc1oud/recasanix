{
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-user-service";
  # upstream: common/version.go
  version = "0.4.8";
  inherit src;
  vendorHash = "sha256-iD5wgHsaaYfzjKNacEFnNzzQEFft0L2zOlVqHmiwGHc=";
  patches = [
    ./patches/0001-drop-local-storage-listener.patch
    ./patches/0002-feat-gatewayclient-service-credential-helpers-for-in.patch
    ./patches/0003-feat-service-present-the-service-credential-to-the-m.patch
  ];
  # go.mod declares Go 1.26.6; nixpkgs' default `go` (1.26.x) satisfies it. If nixpkgs' default moves
  # past what go.mod accepts, pin `go = pkgs.go_1_26` through mkCasaosGo.
  subPackages = [ "." ];
  renameBinaries.ReCasaOS-UserService = "casaos-user-service";
  repo = components.recasaos-user-service.repo;
  description = "ReCasaOS user service: accounts, sessions and JWT issuance";
  mainProgram = "casaos-user-service";
}
