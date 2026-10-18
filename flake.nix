{
  description = "peerpatrol: hash-scheduled peer checks, alarms via a shared Telegram chat";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in pkgs.stdenv.mkDerivation {
      name = "peerpatrol";
      # Zig 0.16 pinned; static linux amd64 (musl, baseline cpu).
      nativeBuildInputs = [ pkgs.zig ];

      src = pkgs.lib.cleanSourceWith {
        src = ./.;
        filter = path: type: let
          n = baseNameOf (toString path);
        in !(n == ".zig-cache" || n == ".scratch" || n == ".git" || n == ".opencode" || n == "zig-out" || n == "node_modules");
      };

      # zig needs a writable cache dir; $HOME does not exist in derivations.
      XDG_CACHE_HOME = "$TMPDIR";

      installPhase = ''
        mkdir -p $out/bin
        zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl --prefix $out install
      '';
    };

    # wiring example: `nixosModules.default` on each monitoring member host.
    # Import in your flake:  specialArgs { monitoring = self; } then
    #   imports = [ monitoring.nixosModules.default ];
    #   services.peerpatrol = { enable = true; configFile = ./config.json; };
    nixosModules.default = { config, lib, pkgs, self, ... }: {
      options.services.peerpatrol = {
        enable = lib.mkEnableOption "decentralized-monitoring agent (peer checks, Telegram alarms)";
        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.x86_64-linux.default;
          defaultText = "peerpatrol";
          description = "The agent package; override only for testing.";
        };
        configFile = lib.mkOption {
          type = lib.types.path;
          description = "Shared JSON config, identical on every member host.";
        };
      };

      config = lib.mkIf config.services.peerpatrol.enable {
        systemd.services.peerpatrol = {
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${config.services.peerpatrol.package}/bin/peerpatrol ${config.services.peerpatrol.configFile}";
            Restart = "on-failure";
            RestartSec = 5;
            # unprivileged run; ambient cap so shelled-out `ping` can open raw sockets
            DynamicUser = true;
            AmbientCapabilities = "cap_net_raw";
            # writable cwd for the agent's default state_path (`monitor-state.txt`);
            # systemd makes the state dir the working directory when WorkingDirectory is unset
            StateDirectory = "peerpatrol";
          };
        };
      };
    };

    # hidden check host: boots a VM whose hostname matches the example config.
    # usage: nix build .#nixosConfigurations.agent-vm-check.config.system.build.vm
    nixosConfigurations.agent-vm-check = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs.self = self;
      modules = [
        self.nixosModules.default
        {
          networking.hostName = "example-host";
          boot.kernelParams = [ "console=ttyS0" "systemd.show_status=yes" ];
          services.peerpatrol = {
            enable = true;
            configFile = ./config.example.json;
          };

          # boot-time report, the VM console needs no login to verify the unit
          systemd.services.vm-check-report = {
            wantedBy = [ "multi-user.target" ];
            requires = [ "peerpatrol.service" ];
            after = [ "peerpatrol.service" "network-online.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.StandardOutput = "journal+console";
            serviceConfig.StandardError = "journal+console";
            script = ''
              sleep 15
              echo "VMCHECK: peerpatrol is $(systemctl is-active peerpatrol)" > /dev/ttyS0 || true
              echo "VMCHECK-LOG: $(journalctl -u peerpatrol -b --no-pager | tail -2)" > /dev/ttyS0 || true
              sleep 2
              systemctl poweroff --no-wall
            '';
          };
        }
      ];
    };
  };
}
