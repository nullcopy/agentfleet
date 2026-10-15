# Exercises the built-in harness, an inline test harness and both agent
# sources. Used by `nix flake check` (evaluation only) and handy as a reference.
{ pkgs, lib, ... }:

{
  system.stateVersion = "25.11";
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };

  services.agentfleet = {
    registry.dir = ./example-registry;
    flakeDir = "/etc/nixos";

    # A minimal harness defined on the host itself: any command as a service.
    harnesses.custom = {
      description = "run settings.exec as the agent";
      exec = ag: ag.settings.exec or null;
      init = ag: ag.settings.init or "";
    };

    agents.echo = {
      harness = "custom";
      settings.exec = "${pkgs.coreutils}/bin/sleep infinity";
      memoryMax = "256M";
    };

    agents.scribe = {
      harness = "hermes";
      model = "anthropic/claude-sonnet-5.5";
      description = "second Hermes agent";
    };

    agents.parked = {
      harness = "hermes";
      enable = false;
    };
  };
}
