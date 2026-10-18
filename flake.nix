{
  description = "decentralized-monitoring agent: hash-scheduled peer checks, alarms via a shared Telegram chat";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in pkgs.stdenv.mkDerivation {
      name = "decentralized-monitoring-agent";
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

      passthru = {
        # fast feedback loop outside nix
        smokeTest = pkgs.runCommand "agent-smoke" {} ''
          ${self.packages.x86_64-linux.default}/bin/agent
          test $? != 0 && echo smoke-ok
        '';
      };
    };

    # wiring example: `nixosModules.default` on each monitoring member host.
    # Import in your flake:  specialArgs { monitoring = self; } then
    #   imports = [ monitoring.nixosModules.default ];
    #   services.monitorAgent = { enable = true; configFile = ./config.json; };
    nixosModules.default = { config, lib, pkgs, self, ... }: {
      options.services.monitorAgent = {
        enable = lib.mkEnableOption "decentralized-monitoring agent (peer checks, Telegram alarms)";
        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.x86_64-linux.default;
          defaultText = "decentralized-monitoring-agent";
          description = "The agent package; override only for testing.";
        };
        configFile = lib.mkOption {
          type = lib.types.path;
          description = "Shared JSON config, identical on every member host.";
        };
      };

      config = lib.mkIf config.services.monitorAgent.enable {
        systemd.services.monitor-agent = {
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${config.services.monitorAgent.package}/bin/agent ${config.services.monitorAgent.configFile}";
            Restart = "on-failure";
            RestartSec = 5;
            # unprivileged run; ambient cap so shelled-out `ping` can open raw sockets
            DynamicUser = true;
            AmbientCapabilities = "cap_net_raw";
            # writable cwd for the agent's default state_path (`monitor-state.txt`);
            # systemd makes the state dir the working directory when WorkingDirectory is unset
            StateDirectory = "monitor-agent";
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
          boot.kernelParams = [ "console=ttyS0" ];
          services.monitorAgent = {
            enable = true;
            configFile = ./config.example.json;
          };

          # boot-time report, the VM console needs no login to verify the unit
          systemd.services.vm-check-report = {
            wantedBy = [ "multi-user.target" ];
            requires = [ "monitor-agent.service" ];
            after = [ "monitor-agent.service" "network-online.target" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.StandardOutput = "journal+console";
            serviceConfig.StandardError = "journal+console";
            script = ''
              sleep 15
              echo "VMCHECK: monitor-agent is $(systemctl is-active monitor-agent)" > /dev/ttyS0 || true
              echo "VMCHECK-LOG: $(journalctl -u monitor-agent -b --no-pager | tail -2)" > /dev/ttyS0 || true
              sleep 2
              systemctl poweroff --no-wall
            '';
          };
        }
      ];
    };
  };
}
