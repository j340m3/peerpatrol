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
    # Import from your flake (package must be set; this flake's `self` is not
    # visible in module args from outside):
    #   imports = [ inputs.peerpatrol.nixosModules.default ];
    #   services.peerpatrol = {
    #     package = inputs.peerpatrol.packages.x86_64-linux.default;
    #     configFile = ./config.json;
    #   };
    # Root-readable secret files (e.g. sops-nix) go through tokenFile /
    # chatIdFile: systemd copies them into the unit via LoadCredential and
    # passes --token-file/--chat-id-file, so DynamicUser can read them.
    nixosModules.default = { config, lib, pkgs, ... }:
      let cfg = config.services.peerpatrol;
      in {
        options.services.peerpatrol = {
          enable = lib.mkEnableOption "decentralized-monitoring agent (peer checks, Telegram alarms)";
          package = lib.mkOption {
            type = lib.types.package;
            description = "The agent package; importing flakes set this explicitly (this flake is not visible in module args from outside).";
          };
          configFile = lib.mkOption {
            type = lib.types.path;
            description = "Shared JSON config, identical on every member host.";
          };
          tokenFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File containing the Telegram bot token (text); overrides the config JSON `telegram.bot_token`. Typical source: sops-nix secret.";
          };
          chatIdFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "File containing the Telegram chat id (integer text); overrides the config JSON `telegram.chat_id`.";
          };
        };

        config = lib.mkIf cfg.enable {
          systemd.services.peerpatrol = {
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            serviceConfig = {
              ExecStart = lib.concatStringsSep " " (
                [ "${cfg.package}/bin/peerpatrol" "${cfg.configFile}" ]
                ++ lib.optional (cfg.tokenFile != null) "--token-file %d/peerpatrol-token-file"
                ++ lib.optional (cfg.chatIdFile != null) "--chat-id-file %d/peerpatrol-chat-id-file"
              );
              LoadCredential = lib.optional (cfg.tokenFile != null) "peerpatrol-token-file:${cfg.tokenFile}"
                ++ lib.optional (cfg.chatIdFile != null) "peerpatrol-chat-id-file:${cfg.chatIdFile}";
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
      modules = [
        self.nixosModules.default
        {
          networking.hostName = "example-host";
          # minimal bootable disk for qemu; nix flake check evals the
          # toplevel and asserts these exist
          fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
          boot.loader.grub.devices = [ "/dev/vda" ];
          boot.kernelParams = [ "console=ttyS0" "systemd.show_status=yes" ];
          system.stateVersion = "25.05";
          services.peerpatrol = {
            enable = true;
            package = self.packages.x86_64-linux.default;
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
