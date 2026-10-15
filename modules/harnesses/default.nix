# Built-in harness recipes. Each file registers one entry under
# services.agents.harnesses.<name>. Add your own by writing a module that sets
# another entry; see README "Writing a harness".
{
  imports = [
    ./hermes.nix
    ./claude-code.nix
    ./openclaw.nix
    ./custom.nix
  ];
}
