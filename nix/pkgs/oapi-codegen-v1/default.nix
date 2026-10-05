# oapi-codegen v1.12.4 — the exact generator upstream's `go:generate` lines pin
# (`go run github.com/deepmap/oapi-codegen/cmd/oapi-codegen@v1.12.4`). nixpkgs ships 2.x, whose
# output imports a different runtime module and does not compile against the vendored dependencies.
# Build-time tool only; used by casaos-app-management, whose generated code is gitignored upstream.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "oapi-codegen";
  version = "1.12.4";

  src = fetchFromGitHub {
    owner = "deepmap";
    repo = "oapi-codegen";
    rev = "v${finalAttrs.version}";
    hash = "sha256-VbaGFTDfe/bm4EP3chiG4FPEna+uC4HnfGG4C7YUWHc=";
  };

  vendorHash = "sha256-o9pEeM8WgGVopnfBccWZHwFR420mQAA4K/HV2RcU2wU=";
  subPackages = [ "cmd/oapi-codegen" ];
  doCheck = false;

  meta = {
    description = "OpenAPI 3 client/server code generator, pinned to the version ReCasaOS uses";
    homepage = "https://github.com/deepmap/oapi-codegen";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "oapi-codegen";
  };
})
