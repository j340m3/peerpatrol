{
  description = "peerpatrol: hash-scheduled peer checks, alarms via a shared Telegram chat";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      supported = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # All packages build on the default x86_64 builder: zig cross-compiles
      # natively, so even the aarch64 artifact is a plain local build
      # (pkgsCross.aarch64-linux callPackage'd without a foreign builder).
      # All packages build on the default x86_64 builder: zig cross-compiles
      # natively, so the aarch64 artifact is a plain local build too.
      packages = {
        x86_64-linux.default = (pkgsFor "x86_64-linux").callPackage ./package.nix { };
        aarch64-linux.default =
          (pkgsFor "x86_64-linux").pkgsCross.aarch64-multiplatform.callPackage ./package.nix
            { };
      };

      # wiring example: see nixos/module.nix
      nixosModules.default = ./nixos/module.nix;

      checks = nixpkgs.lib.genAttrs supported (system: {
        peerpatrol-vm = (pkgsFor system).testers.runNixOSTest ./tests/vm.nix;
      });

      # manual boot toy for debugging: `nix build .#nixosConfigurations.agent-vm-check.config.system.build.vm`
      # then boot the result. Same loopback config as checks.peerpatrol-vm.
      nixosConfigurations.agent-vm-check = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          ./tests/node.nix
          ({
            lib,
            pkgs,
            ...
          }: {
            # the manual toy exercises the shipped example config instead of
            # the loopback test config (no runTest scaffolding here)
            services.peerpatrol.configFile = lib.mkForce ./config.example.json;
            fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
            boot.loader.grub.devices = [ "/dev/vda" ];
            boot.kernelParams = [ "console=ttyS0" "systemd.show_status=yes" ];
            system.stateVersion = "25.05";
          })
        ];
      };
    };
}
