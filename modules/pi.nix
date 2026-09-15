# Everything common to a Raspberry Pi 4 in this fleet.
#
# The machine this first ran on was flashed from the stock NixOS aarch64
# sd-image (tasker-shq.4). Two things below exist purely to keep it bootable
# across that handover, and both are load-bearing rather than decorative:
# the filesystems are declared by the LABELS the image created, and the
# extlinux bootloader is kept enabled. Drop either and the next reboot is a
# recovery job with a card reader.
{ config, lib, pkgs, ... }:

{
  # --- boot -----------------------------------------------------------------
  # The Pi has no EFI and no grub. u-boot on the FAT firmware partition reads
  # /boot/extlinux/extlinux.conf from the ext4 root, so this must stay on.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # DELIBERATELY NOT IMPORTING nixos-hardware's raspberry-pi-4 module. Measured
  # twice during planning: it selects a vendor kernel that is not on the binary
  # cache for 26.05, turning ~26 trivial derivations into ~40 including a full
  # kernel compile that this board should not be asked to do. The mainline
  # kernel in the stock image already boots this hardware.

  boot.initrd.availableKernelModules = [
    "xhci_pci" # the Pi 4's USB controller
    "uas" # USB attached SCSI, for the SSD hanging off it
  ];

  # Serial and HDMI both, matching the sd-image. This is the recovery console
  # when a change takes the network with it (tasker-shq.2), so it is worth
  # keeping even though provisioning no longer needs it.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=tty0"
  ];

  # --- filesystems ----------------------------------------------------------
  # By LABEL, not by UUID: these are the labels the sd-image writes, and a
  # label survives re-flashing a replacement card where a UUID does not.
  # `nixos-generate-config` on this box omitted /boot/firmware entirely,
  # because the image leaves it noauto and therefore unmounted at scan time.
  # Copying that output verbatim would have silently dropped the partition
  # that holds u-boot.
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "x-initrd.mount" ];
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    # nofail + noauto exactly as the image had it: the firmware partition is
    # only needed when updating u-boot, and a missing one must not wedge boot.
    options = [
      "nofail"
      "noauto"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = "aarch64-linux";

  # --- access ---------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      # The installer image shipped both root and the `nixos` user with EMPTY
      # password hashes. Over the network that was already unexploitable
      # (PermitEmptyPasswords defaults to no, and pam_unix has no nullok on the
      # sshd auth line -- an actual empty-password attempt was refused). This
      # closes it properly rather than resting on those defaults.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root.openssh.authorizedKeys.keys = [
    # rb, the same key that authorises the vault. Declared here so it is part
    # of the configuration rather than a file someone injected into the card
    # once and cannot account for later.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHcfI9CaeXPtYhs//VLjDaqcBhNfHQ9B8Bh7YRH/hSr+ ambientself@gmail.com"
  ];

  # The image autologs a `nixos` user into a console with passwordless sudo,
  # and gives both it and root empty password hashes. That account is defined
  # by profiles/installation-device.nix, which this configuration does not
  # import -- so it simply ceases to exist at the switch. Nothing is declared
  # here to remove it on purpose: in NixOS, naming users.users.nixos would
  # CREATE the account rather than delete it.

  # --- discovery ------------------------------------------------------------
  # DHCP without mDNS means finding this box is an ARP sweep every time, and
  # the address moves. The vault is reachable as vault.local for exactly this
  # reason; match it.
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    nssmdns4 = true;
  };
  networking.firewall.allowedUDPPorts = [ 5353 ];

  # --- secrets --------------------------------------------------------------
  sops = {
    # EXPLICIT, not inherited. The module derives this default from the
    # configured SSH host keys ONLY when the SSH server is enabled, and is an
    # empty list otherwise -- and the resulting failure reads as a decryption
    # problem rather than a configuration one. sshd is enabled just above, so
    # the default would in fact be correct here, which is precisely what makes
    # relying on it silently a bad habit to start.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # A canary rather than a fabricated credential. It proves the whole chain
    # -- host key -> age identity -> decryption at activation -> a file on
    # disk -- without inventing a secret this machine has no use for yet.
    secrets.bootstrap_canary = {
      mode = "0400";
      owner = "root";
    };
  };

  # --- converging -----------------------------------------------------------
  # comin polls this repository and deploys it. Chosen over system.autoUpgrade
  # for one disqualifying reason: autoUpgrade resolves a MUTABLE flake ref, and
  # when the forge cannot be reached Nix falls back to its cached resolution
  # with only a warning. The unit then builds an older revision, prints
  # "Finished NixOS Upgrade" and exits zero. A stale deploy that reports success
  # cannot be caught by OnFailure=, because nothing failed. comin fetches with
  # its own git implementation and is not exposed to that.
  #
  # It builds ON THE BOX, which is only sane because this configuration stays on
  # the binary cache. If it ever drifts off, comin is the wrong shape -- the
  # daemon sits on a Pi 4 trying to compile, and the outcome is a thermal
  # shutdown or an OOM kill. That is the same reason nixos-hardware is absent
  # above: the guides that recommend this stack usually recommend that module in
  # the same breath, and the two pieces of advice are incompatible.
  services.comin = {
    enable = true;
    remotes = [
      {
        name = "origin";
        # Anonymous https, no auth block, no deploy key, nothing to rotate or
        # lose. That is what the public-repo decision bought; the cost is that
        # the fleet map is public, which is a reconnaissance cost rather than a
        # secrets one.
        url = "https://github.com/ambientself/nixos-config.git";
        poller.period = 60;

        # BOOT, NOT SWITCH, for the unattended branch. The boot path installs
        # the bootloader and syncs BEFORE touching any running unit, so an
        # unattended deploy cannot half-restart this box into an unreachable
        # state. The cost is that a change on main lands at the next reboot.
        branches.main.operation = "boot";

        # `branches.testing` is deliberately left at its default, which is
        # testing-${hostname} with `test` semantics. Two reasons: test does not
        # touch the bootloader, so a power cycle returns the box to its last
        # good generation -- the closest thing to a safety net that exists,
        # since no pull tool in this space has automatic rollback. And the
        # default derives the branch name from the hostname, so this shared
        # module gives every Pi its own testing branch without naming any host.
        #
        # So: push risky work to testing-pi1 and watch it live, merge to main
        # when it holds.
      }
    ];

    # The exporter's default listen_address is the empty string, which means
    # every interface. Nothing needs it off-box yet, and the firewall is not the
    # right place to rely on for something that should not be listening widely
    # in the first place. openFirewall stays false; when a scraper does need it,
    # that is the knob, not this one.
    exporter.listen_address = "127.0.0.1";

    # Explicit even though both already default to 1800. There is a long-open
    # report of an upgrade unit hanging for four days and blocking every other
    # Nix operation on the box, and on this hardware a wedged rebuild is not
    # something a headless machine recovers from on its own.
    evalTimeout = 1800;
    buildTimeout = 1800;
  };

  # --- housekeeping ---------------------------------------------------------
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # The card is 64G and the store only grows. Disk exhaustion is the realistic
  # failure here, not card wear.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.settings.auto-optimise-store = true;

  time.timeZone = "UTC";
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  # Matches the release this was installed from. Not a version to bump
  # casually: it pins stateful defaults, not the package set.
  system.stateVersion = "26.05";
}
