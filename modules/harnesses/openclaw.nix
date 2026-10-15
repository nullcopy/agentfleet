# OpenClaw — long-running gateway with its own control UI and chat channels.
#
# nixpkgs marks openclaw as insecure (prompt-injection warning). Rather than
# requiring nixpkgs.config.permittedInsecurePackages on every host, the default
# package here clears that flag; the risk is unchanged and is exactly why each
# agent gets its own user and optional egress policy.
#
# Every OpenClaw agent runs its own gateway. The default port is 18789, so a
# second OpenClaw agent on the same host needs
#   settings.gateway.port = 18790   (agentctl add ... --set gateway.port=18790)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  h = config.services.agents.harnesses.openclaw;
in
{
  services.agents.harnesses.openclaw = {
    description = "OpenClaw gateway; long-running, multi-channel";
    package = lib.mkDefault (
      pkgs.openclaw.overrideAttrs (old: {
        meta = (old.meta or { }) // {
          knownVulnerabilities = [ ];
        };
      })
    );

    secrets = [
      {
        name = "OPENCLAW_GATEWAY_TOKEN";
        required = true;
        description = "Shared secret for the gateway API and control UI (auth is mandatory)";
      }
      {
        name = "ANTHROPIC_API_KEY";
        description = "Anthropic API key";
      }
      {
        name = "OPENAI_API_KEY";
        description = "OpenAI API key";
      }
      {
        name = "OPENROUTER_API_KEY";
        description = "OpenRouter API key";
      }
    ];

    environment = ag: {
      OPENCLAW_STATE_DIR = "${ag.home}/.openclaw";
      OPENCLAW_CONFIG_PATH = "${ag.home}/.openclaw/openclaw.json";
    };

    exec = ag: "${lib.getExe h.package} gateway";

    init = ag: ''
      mkdir -p "$OPENCLAW_STATE_DIR/workspace"
    '';

    # Seeded: OpenClaw edits its own config (pairing, channel setup) and
    # refuses a symlinked config, so this is a real file written once.
    files = ag: {
      ".openclaw/openclaw.json" = {
        mode = "seed";
        text = builtins.toJSON (
          lib.recursiveUpdate (
            {
              gateway = {
                bind = "loopback";
                auth.mode = "token";
              };
              agents.defaults.workspace = "${ag.home}/.openclaw/workspace";
            }
            // lib.optionalAttrs (ag.model != null) { agents.defaults.model.primary = ag.model; }
          ) ag.settings
        );
      };
    };
  };
}
