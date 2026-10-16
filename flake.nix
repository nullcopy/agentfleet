{
  description = "agentfleet: a fleet of Hermes agents on one NixOS host, each its own user, each on the fleet's Matrix server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Hermes Agent is not in nixpkgs; its flake provides the package and is
    # pinned to its own nixpkgs so the Python/Node lock it was tested against
    # is honoured. Add `inputs.hermes-agent.inputs.nixpkgs.follows = "nixpkgs";`
    # in your own flake if you prefer a single nixpkgs and accept the risk.
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.default =
        { pkgs, lib, ... }:
        {
          imports = [ ./modules ];
          services.agentfleet.hermesPackage =
            lib.mkDefault
              hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      packages = forAll (
        system: pkgs: rec {
          agentctl = pkgs.callPackage ./pkgs/agentctl { };
          agentfleet-matrix = pkgs.callPackage ./pkgs/agentfleet-matrix { };
          default = agentctl;
        }
      );

      checks = forAll (
        system: pkgs:
        let
          example = nixpkgs.lib.nixosSystem {
            modules = [
              { nixpkgs.hostPlatform = system; }
              self.nixosModules.default
              ./checks/example-host.nix
            ];
          };
        in
        {
          # Evaluates the module and renders the units. The string context is
          # dropped so the agents' profiles are not built.
          eval = pkgs.writeText "agentfleet-eval" (
            builtins.unsafeDiscardStringContext (
              assert builtins.any (p: (p.pname or "") == "agentctl") example.config.environment.systemPackages;
              assert example.config.systemd.services."agent@".serviceConfig.User == "agent-%i";
              example.config.environment.etc."agents/state.json".text
              + "\n"
              + example.config.environment.etc."agents/matrix.json".text
              + "\n"
              + example.config.systemd.units."agent@.service".text
              + "\n"
              + example.config.systemd.units."agentfleet-agents.service".text
            )
          );
          agentctl = self.packages.${system}.agentctl;
          agentfleet-matrix = self.packages.${system}.agentfleet-matrix;
          vm = import ./checks/vm-test.nix { inherit pkgs self; };
        }
      );

      formatter = forAll (_: pkgs: pkgs.nixfmt);
    };
}
