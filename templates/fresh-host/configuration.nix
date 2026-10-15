# Minimal headless agent host. Adjust users, SSH keys and disks, then:
#   sudo nixos-rebuild switch --flake /etc/nixos
{ lib, pkgs, ... }:

{
  networking.hostName = "agenthost";
  time.timeZone = "UTC";
  system.stateVersion = "25.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  ## ----- operator access -----------------------------------------------------
  users.users.operator = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@laptop"
    ];
  };
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  security.sudo.wheelNeedsPassword = false;

  ## ----- firewall: required for per-agent egress policies ---------------------
  networking.firewall.enable = true;
  networking.nftables.enable = true;

  ## ----- harness licences -----------------------------------------------------
  # Claude Code is unfree in nixpkgs.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  ## ----- agents ---------------------------------------------------------------
  services.agents = {
    # Where this flake is checked out on the host; agentctl writes here.
    flakeDir = "/etc/nixos";
    # One TOML file per agent; agentctl add/rm manage this directory.
    registry.dir = ./agents;

    # Agents can also be declared right here. Both sources are merged.
    # agents.reviewer = {
    #   harness = "claude-code";
    #   model = "claude-opus-5-5";
    # };
  };

  environment.systemPackages = with pkgs; [
    vim
    htop
  ];
}
