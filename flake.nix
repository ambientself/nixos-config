{
  description = "Raspberry Pi fleet, pulled from git";

  inputs = {
    # PINNED TO THE REVISION THE SD-IMAGE WAS BUILT FROM, deliberately, not to a
    # channel branch. Cache alignment is the architecture here: a Pi that stays
    # on the binary cache assembles text files and needs no build infrastructure
    # anywhere, and the cheapest way to stay there is to ask for the closure the
    # machine already has on disk. Moving this is a real decision -- re-run the
    # substitutability check on the target afterwards, never only on the Mac.
    nixpkgs.url = "github:NixOS/nixpkgs/21a67dc470149f337cecafbe965d8d252a390518";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      # Without this sops-nix drags in its own nixpkgs, and the box ends up
      # holding two full closures that differ in every path.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, sops-nix }:
    let
      # Adding a Pi is one line in `nixosConfigurations` below (tasker-shq.6).
      # Identical nodes get no per-host directory: they share every module and
      # differ only by name, so standing one up as a replacement for another is
      # a rename rather than a merge.
      mkPi =
        name: extraModules:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/pi.nix
            {
              networking.hostName = name;
              # Per-host secrets live in their own file, so one machine's
              # compromise does not hand over another's.
              sops.defaultSopsFile = ./. + "/secrets/${name}.yaml";
            }
          ] ++ extraModules;
        };
    in
    {
      nixosConfigurations = {
        pi1 = mkPi "pi1" [ ];
      };
    };
}
