{
  description = "agentfleet: one Unix user per AI agent, declared in NixOS and driven by agentctl";

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
      nixosModules = {
        # Everything, with Hermes wired in from the flake input.
        default =
          { pkgs, lib, ... }:
          {
            imports = [ self.nixosModules.core ];
            services.agentfleet.harnesses.hermes.package =
              lib.mkDefault
                hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
          };

        # Module + built-in recipes, no flake-input packages. Set
        # services.agentfleet.harnesses.hermes.package yourself if you use Hermes.
        core = {
          imports = [
            ./modules
            ./modules/harnesses
          ];
        };
      };

      packages = forAll (
        system: pkgs: rec {
          agentctl = pkgs.callPackage ./pkgs/agentctl { };
          default = agentctl;
        }
      );

      overlays.default = final: _prev: { agentctl = final.callPackage ./pkgs/agentctl { }; };

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
          # A freshly installed host: registry configured, no agents yet.
          # agentctl and state.json must still be there.
          fresh = nixpkgs.lib.nixosSystem {
            modules = [
              { nixpkgs.hostPlatform = system; }
              self.nixosModules.default
              ./checks/example-host.nix
              {
                services.agentfleet.agents = nixpkgs.lib.mkForce { };
                services.agentfleet.registry.dir = nixpkgs.lib.mkForce ./checks/empty-registry;
              }
            ];
          };
          freshOk =
            assert fresh.config.services.agentfleet.enable;
            assert builtins.any (p: (p.pname or "") == "agentctl") fresh.config.environment.systemPackages;
            fresh.config.environment.etc."agents/state.json".text;
        in
        {
          # Evaluates every built-in recipe and renders the units. The string
          # context is dropped so the agents' profiles are not built.
          eval = pkgs.writeText "agentfleet-eval" (
            builtins.unsafeDiscardStringContext (
              example.config.environment.etc."agents/state.json".text
              + "\n"
              + freshOk
              + "\n"
              + builtins.concatStringsSep "\n" (
                nixpkgs.lib.filter (nixpkgs.lib.hasPrefix "agent-") (
                  builtins.attrNames example.config.systemd.services
                )
              )
            )
          );
          agentctl = self.packages.${system}.agentctl;
          vm = import ./checks/vm-test.nix { inherit pkgs self; };
        }
      );

      formatter = forAll (_: pkgs: pkgs.nixfmt);
    };
}
