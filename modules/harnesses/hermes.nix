# Hermes Agent (Nous Research) — long-running messaging gateway.
#
# The package is not in nixpkgs; agentfleet.nixosModules.default wires it from
# the hermes-agent flake input. If you import nixosModules.core instead, set
# services.agentfleet.harnesses.hermes.package yourself.
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.agentfleet;
  h = cfg.harnesses.hermes;
  usedBy = lib.filterAttrs (_: a: a.enable && a.harness == "hermes") (
    cfg.agents // cfg.registry.agents
  );
in
{
  services.agentfleet.harnesses.hermes = {
    description = "Hermes Agent gateway (Nous Research); long-running, chat-platform driven";

    secrets = [
      {
        name = "ANTHROPIC_API_KEY";
        description = "Anthropic API key";
      }
      {
        name = "OPENROUTER_API_KEY";
        description = "OpenRouter API key";
      }
      {
        name = "OPENAI_API_KEY";
        description = "OpenAI or OpenAI-compatible endpoint key";
      }
      {
        name = "TELEGRAM_BOT_TOKEN";
        description = "Telegram bot token, if the Telegram platform is enabled in settings";
      }
      {
        name = "DISCORD_BOT_TOKEN";
        description = "Discord bot token, if the Discord platform is enabled in settings";
      }
    ];

    environment = ag: {
      HERMES_HOME = "${ag.home}/.hermes";
    };

    # Same argv the upstream NixOS module uses for its gateway unit.
    exec = ag: "${lib.getExe' h.package "hermes"} gateway";

    init = ag: ''
      mkdir -p "$HERMES_HOME"
    '';

    # Seeded once: Hermes rewrites config.yaml itself (`hermes config set`),
    # so overwriting it on every rebuild would clobber the agent's own changes.
    # YAML is a superset of JSON, so toJSON produces a valid config.yaml.
    files = ag: {
      ".hermes/config.yaml" = {
        mode = "seed";
        text = builtins.toJSON (
          lib.recursiveUpdate (lib.optionalAttrs (ag.model != null) { model.default = ag.model; }) ag.settings
        );
      };
    };
  };

  assertions = [
    {
      assertion = usedBy == { } || h.package != null;
      message = "agentfleet: agents ${lib.concatStringsSep ", " (lib.attrNames usedBy)} use harness 'hermes' but services.agentfleet.harnesses.hermes.package is unset. Import agentfleet.nixosModules.default (which sets it from the hermes-agent flake input) or set it explicitly.";
    }
  ];
}
