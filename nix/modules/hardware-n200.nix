# Task 4.4 — the N200 board. Deliberately near-empty until the hardware prototype arrives: the
# generic x86 defaults below are what nearly every Intel board needs to find its boot media and bring
# its NIC up, and everything board-specific is a TODO to be settled against the real machine.
_: {
  # Firmware blobs (NIC, Wi-Fi/BT if fitted, GPU) and CPU microcode.
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # Every medium the board can boot from or hold data on: eMMC, NVMe, SATA and USB. The initrd must
  # be able to reach the root partition whichever of them the image was flashed to.
  # TODO(hardware): trim to what the board actually uses once `lspci -k` / `lsmod` are known.
  boot.initrd.availableKernelModules = [
    "sdhci_pci" # eMMC
    "mmc_block"
    "nvme"
    "ahci" # SATA
    "sd_mod"
    "xhci_pci" # USB
    "usb_storage"
  ];

  # TODO(hardware) — the likely custom work, none of it needed to boot:
  #   * status LEDs and their meaning (power, disk activity, disk fault)
  #   * front-panel / reset button (gpio-keys or a vendor EC driver)
  #   * fan control (hwmon/thermal zones or an EC)
  #   * disk-bay identification — which physical bay a /dev/sdX or nvme device sits in
  #   * NIC: model not known yet (a single Ethernet port is expected) — identify it with lspci -k,
  #     confirm its driver is in the kernel and that the link comes up
}
