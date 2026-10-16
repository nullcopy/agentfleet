# The platform as a host would configure it. Used by `nix flake check`
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
    enable = true;
    extraPackages = [ pkgs.python3 ];
    matrix = {
      serverName = "matrix.example.org";
      operator = "@alice:example.com";
      listenAddresses = [ "10.0.0.2" ]; # reverse proxy on another machine
    };
  };
}
