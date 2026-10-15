# Exercises both agent sources and the Matrix server. Used by `nix flake check`
# (evaluation only) and handy as a reference.
{ pkgs, lib, ... }:

{
  system.stateVersion = "25.11";
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  networking.hostName = "example";

  services.agentfleet = {
    registry.dir = ./example-registry;
    flakeDir = "/etc/nixos";

    matrix = {
      serverName = "matrix.example.org";
      operator = "@alice:example.com";
      listenAddresses = [ "10.0.0.2" ]; # reverse proxy on another machine
    };

    agents.scribe = {
      model = "anthropic/claude-sonnet-5.5";
      description = "writes things down";
      matrix.localpart = "scribe2";
      memoryMax = "4G";
    };

    agents.parked = {
      enable = false;
    };
  };
}
