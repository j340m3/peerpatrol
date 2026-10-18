# wiring example: `nixosModules.default` on each monitoring member host.
#   imports = [ inputs.peerpatrol.nixosModules.default ];
#   services.peerpatrol = {
#     configFile = ./config.json;   # identical on every member host
#     # package defaults to this flake's package.nix; override to pin.
#     tokenFile = ./token;          # e.g. a sops-nix secret
#   };
# Root-readable secret files (e.g. sops-nix) go through tokenFile /
# chatIdFile: systemd copies them into the unit via LoadCredential and
# passes --token-file/--chat-id-file, so DynamicUser can read them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.peerpatrol;
in
{
  options.services.peerpatrol = {
    enable = lib.mkEnableOption "decentralized monitoring agent (peer checks, Telegram alarms)";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../package.nix { };
      description = "The agent package. Importers may override to pin their own (e.g. inputs.peerpatrol.packages.x86_64-linux.default).";
    };
    configFile = lib.mkOption {
      type = lib.types.path;
      description = "Shared JSON config, identical on every member host. No per-host `settings` option: generated configs would break the hash-election equivalence (see ADR 0003).";
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
      description = "peerpatrol (peer checks, Telegram alarms)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [ "${lib.getExe cfg.package}" "${cfg.configFile}" ]
          ++ lib.optional (cfg.tokenFile != null) "--token-file %d/peerpatrol-token-file"
          ++ lib.optional (cfg.chatIdFile != null) "--chat-id-file %d/peerpatrol-chat-id-file"
        );
        LoadCredential = lib.optional (cfg.tokenFile != null) "peerpatrol-token-file:${cfg.tokenFile}"
          ++ lib.optional (cfg.chatIdFile != null) "peerpatrol-chat-id-file:${cfg.chatIdFile}";
        Restart = "on-failure";
        RestartSec = 5;
        # unprivileged run; ambient cap so shelled-out `ping` can open raw
        # sockets (the hardening + ping combo is exercised by checks.vm)
        DynamicUser = true;
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        NoNewPrivileges = true;
        # the agent's default state_path is cwd-relative; point cwd at the
        # StateDirectory (the only writable place under ProtectSystem)
        StateDirectory = "peerpatrol";
        WorkingDirectory = "/var/lib/peerpatrol";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        UMask = "0077";
        # deterministic `ping` for the shelled-out probe
        Environment = "PATH=${lib.makeBinPath [ pkgs.iputils ]}";
      };
    };
  };
}
