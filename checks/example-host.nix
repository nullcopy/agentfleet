# Exercises every built-in harness and both agent sources. Used by
# `nix flake check` (evaluation only) and handy as a reference.
{ pkgs, lib, ... }:

{
  system.stateVersion = "25.11";
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  services.agents = {
    registry.dir = ./example-registry;
    flakeDir = "/etc/nixos";

    agents.reviewer = {
      harness = "claude-code";
      model = "claude-opus-5-5";
      description = "on-demand code reviewer";
    };

    agents.echo = {
      harness = "custom";
      settings.exec = "${pkgs.coreutils}/bin/sleep infinity";
      memoryMax = "256M";
    };

    agents.fenced = {
      harness = "openclaw";
      settings.gateway.port = 18790;
    };

    agents.parked = {
      harness = "hermes";
      enable = false;
    };
  };
}
