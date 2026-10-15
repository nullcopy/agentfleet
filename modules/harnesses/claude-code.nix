# Claude Code — on-demand harness. There is no long-running service; use
# `agentctl run <name> -- claude ...` or `agentctl shell <name>`.
#
# claude-code is unfree in nixpkgs. Allow it on the host with e.g.
#   nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
#
# Claude Code's optional tool sandbox uses bubblewrap, which needs user
# namespaces; the default sandbox forbids them (RestrictNamespaces). To use
# it, set `services.agentfleet.harnesses.claude-code.sandbox = _: { RestrictNamespaces = false; };`.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  services.agentfleet.harnesses.claude-code = {
    description = "Claude Code CLI; on-demand, no service";
    package = lib.mkDefault pkgs.claude-code;

    secrets = [
      {
        name = "ANTHROPIC_API_KEY";
        description = "Anthropic API key (or use CLAUDE_CODE_OAUTH_TOKEN)";
      }
      {
        name = "CLAUDE_CODE_OAUTH_TOKEN";
        description = "Long-lived OAuth token from `claude setup-token`";
      }
    ];

    environment = ag: {
      CLAUDE_CONFIG_DIR = "${ag.home}/.claude";
    };

    files = ag: {
      ".claude/settings.json" = {
        mode = "seed";
        text = builtins.toJSON (
          lib.recursiveUpdate (lib.optionalAttrs (ag.model != null) { model = ag.model; }) ag.settings
        );
      };
    };
  };
}
