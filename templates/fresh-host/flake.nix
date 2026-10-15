{
  description = "An agent host built with agentfleet";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentfleet.url = "github:nullcopy/agentfleet";
    # Share one nixpkgs with agentfleet's own module evaluation:
    agentfleet.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, agentfleet, ... }:
    {
      # Rename `agenthost` to your hostname so `nixos-rebuild switch --flake .`
      # resolves without `#name`.
      nixosConfigurations.agenthost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          agentfleet.nixosModules.default
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
}
