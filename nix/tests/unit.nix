# T1 — upstream unit tests, one derivation per component and separate from the package build, so a
# flaky or environment-dependent upstream test cannot block an image build. A test that needs the
# network, root, a daemon or something the Nix sandbox forbids is skipped with a recorded reason
# below, never deleted.
{ lib, pkgs }:
let
  goUnit =
    pkg:
    {
      # Extra `go test` flags — `-skip` patterns. Document every entry with its reason.
      testFlags ? [ ],
      # Go packages (regex on the import path) not tested at all. Document every entry with its reason.
      excludePackages ? null,
      # extra tools the tests run (not the package's runtime inputs)
      testInputs ? [ ],
    }:
    pkg.overrideAttrs (old: {
      doCheck = true;
      nativeBuildInputs = old.nativeBuildInputs or [ ] ++ testInputs;
      # buildGoModule's default checkPhase honours subPackages and would only test the main package.
      checkPhase = ''
        runHook preCheck
        export GOFLAGS=''${GOFLAGS//-trimpath/}
        # bounded, so a test waiting on the network fails instead of hanging the check forever
        go test -timeout 300s ${
          if excludePackages == null then
            "./..."
          else
            "$(go list ./... | grep -vE ${lib.escapeShellArg excludePackages})"
        } ${lib.escapeShellArgs testFlags}
        runHook postCheck
      '';
      postInstall = "";
      installPhase = "mkdir -p $out";
      dontFixup = true;
    });
in
{
  unit-casaos-gateway = goUnit pkgs.casaos-gateway { };
  unit-casaos-message-bus = goUnit pkgs.casaos-message-bus { };
  unit-recasanix-storage = goUnit pkgs.recasanix-storage { };
  unit-casaos-user-service = goUnit pkgs.casaos-user-service { };

  unit-casaos-app-management = goUnit pkgs.casaos-app-management {
    # git-deployed apps: the tests drive a real git (and ssh for deploy keys) on local repositories
    testInputs = [
      pkgs.git
      pkgs.openssh
    ];
    testFlags = [
      "-skip"
      (lib.concatStringsSep "|" [
        # need a running Docker daemon (the sandbox has none)
        "TestNonExistingContainer"
        "TestTheGitRoutesAreServed"
        "TestPullAndApplyRestoresDotEnvOnFailure"
        # serves a repository over git's smart HTTP (git http-backend as CGI): answers 500 in the
        # sandbox. TODO: find out why before git-deployed apps are decided (register: finding)
        "TestATokenReachesGitThroughAskpassOnly"
        "TestCurrentArchitecture"
        # need the network — public registry, github.com (none in the sandbox)
        "TestGetManifest[123]"
        "TestDownload"
        # download the public app store (TestAppStoreList blocks until it answers)
        "TestGetComposeApp"
        "TestGetApp"
        "TestSkipUpdateCatalog"
        "TestAppStoreList"
      ])
    ];
  };

  unit-casaos = goUnit pkgs.casaos {
    # Debian host management, absent on ReCasaNix (`[server] ImageManaged`, docs/upstream-exclusions.md):
    # the module assistant (apt, archives, unit enable) and the OS-upgrade plan. Their tests run shell
    # scripts that expect /bin/mv, apt, dpkg, setsid and wall-clock grace periods the sandbox lacks.
    excludePackages = "/pkg/(modulecmd|osplan)$";
    testFlags = [
      "-skip"
      (lib.concatStringsSep "|" [
        # chmod of setuid/setgid bits is refused inside the Nix build sandbox
        "TestLoadKeyringDirectoryRejectsUnsafeDirectoryAndNoncanonicalPaths/mode_set[ug]id"
        "TestLoadKeyringDirectoryRejectsUnsafeObjectsWithoutBlocking/set[ug]id"
        "TestVerifierRejectsUnsafePermissions/[24]0000600"
        # require every ancestor of the temp dir to be root/service-owned; the sandbox's /build is not
        "TestPrepareSecureDatabaseDirectoryPreservesContentsAndSecuresArtifacts"
        "TestPrepareSecureDatabaseDirectoryIgnoresPermissiveUmask"
        "TestDatabaseDirectoryIdentityDetectsRenameAndReplacement"
        "TestSQLiteWALArtifactsRemainServiceOwnedSingleLinkMode0600"
        "TestGetDbSMBCredentialSchemaIntegration"
        # lists casaos* units through systemd, which the sandbox does not run
        "TestPorts"
        # OS upgrade and Docker package update (host management, absent here, see excludePackages):
        # runbook/driver scripts expect /bin/mv, rm, apt, dpkg in a Debian layout
        "^TestACheckThatBlock8StoppedIsMadeAgainThroughTheCoreAndTheDriver$"
        "^TestAHopThroughTheCoreTheDriverAndTheRealBlocksFromTheStartToTheClosing$"
        "^TestARehearsalThroughTheCoreTheDriverAndTheRealBlocks$"
        "^TestTheDirectoryIsRemovedOnEveryWayOutOfThePlan$"
        "^TestTheFakeDpkgDropsTheHoldOfWhatItUnpacks$"
        "^TestTheGuardGoesByTheNamesForAnInstThatAptPrintsAsNew$"
        "^TestTheUnitCountsOnlyWhatIsOnHoldAndInstalledAmongTheNamesTheCoreSaw$"
        "^TestTheUnitDoesNotChangeAHoldItWasNotToldToGoAheadOf$"
        "^TestTheUnitDoesNotReportAVersionThatIsNotOne$"
        "^TestTheUnitDoesNotTrustWhatTheProgramsPrint$"
        "^TestTheUnitDoesNotWaitForAContainerThatHasNoPolicy$"
        "^TestTheUnitDownloadsBeforeItChangesAnything$"
        "^TestTheUnitGoesAheadOfAHoldItWasToldToAndPutsItBack$"
        "^TestTheUnitGoesAheadWhenEveryHoldAmongTheNamesIsListed$"
        "^TestTheUnitHasNoVersionToCheckWhenDockerCEIsNotInThePlan$"
        "^TestTheUnitInstallsTheNewDependenciesOfTheNewEngine$"
        "^TestTheUnitPutsBackOnlyTheHoldsItStartedWith$"
        "^TestTheUnitPutsTheHoldBackOnceMoreBeforeItSaysTheHoldsOfARunThatWentThrough$"
        "^TestTheUnitPutsTheHoldBackWhenDpkgIsLockedForAMoment$"
        "^TestTheUnitPutsTheHoldBackWhenTheDaemonNeverComesBack$"
        "^TestTheUnitPutsTheHoldBackWhenTheInstallFailsAfterDpkgUnpackedSome$"
        "^TestTheUnitRefusesAHoldThatWasSetWhileTheDownloadRan$"
        "^TestTheUnitRefusesAWordThatIsNotOneAndRunsNothing$"
        "^TestTheUnitSaysAndKeepsTheHeldPackagesThatThePlanDoesNotTouch$"
        "^TestTheUnitSaysDaemonWhenDockerNeverComesBack$"
        "^TestTheUnitSaysHoldsOnlyAsNamesThatAreItsOwn$"
        "^TestTheUnitSaysRestartPendingWhenTheDaemonIsStillTheOldOne$"
        "^TestTheUnitSaysTheHoldsWhateverEndsTheRun$"
        "^TestTheUnitSaysWhenAHoldCouldNotBePutBack$"
        "^TestTheUnitsDefaultsAreTheWaitsOfTheSpec$"
        "^TestTheUnitStartsDockerOnceWhenItIsDownAfterTheInstall$"
        "^TestTheUnitTakesAHeldNameThatIsOneItMayTouch$"
        "^TestTheUnitTriesOnceToBringDockerBackWhenTheInstallFails$"
        "^TestTheUnitTriesTheHoldAgainWhenARunEndsThatCouldNotPutItBack$"
        "^TestTheUnitUpdatesTheOwnersDocker$"
        "^TestTheUnitWaitsForTheContainersThatComeBack$"
      ])
    ];
  };
}

# unit-casaos-ui is intentionally absent: upstream's `pnpm test` runs `vitest`, which neither
# package.json nor pnpm-lock.yaml declares (only an eslint plugin references it), so the two existing
# spec files cannot run from the locked dependencies. Revisit when upstream adds it (register: TODO).
