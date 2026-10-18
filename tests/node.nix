# The single nixos node used both by tests/vm.nix (checks) and by the
# manual-boot nixosConfigurations.agent-vm-check. Loopback checks only: no
# network or external services needed.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ../nixos/module.nix ];
  networking.hostName = "vmcheck";
  networking.firewall.enable = false;
  services.peerpatrol = {
    enable = true;
    tokenFile = pkgs.writeText "peerpatrol-test-token" "123456:TEST-TOKEN";
    configFile = pkgs.writeText "peerpatrol-test-config.json" (builtins.toJSON {
      telegram = {
        bot_token = "";
        chat_id = 1;
      };
      members = [ "vmcheck" ];
      checks = [
        {
          type = "ping";
          target = "127.0.0.1";
          interval_secs = 3;
        }
        {
          type = "tcp";
          target = "127.0.0.1:1";
          interval_secs = 3;
        }
      ];
    });
  };
  system.stateVersion = "25.05";
}
