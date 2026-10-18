# agentfleet — the platform for a fleet of Hermes agents on one NixOS host.
#
# Nix owns what should change on a rebuild or a rollback: the Hermes package
# and the agents' toolset, the sandbox (one template unit, agent@.service),
# the Matrix server (modules/matrix.nix) and the agentctl tool.
#
# Which agents exist is runtime state, created and destroyed by `agentctl`
# without any rebuild: a system user, a home under /srv/agents, a state
# directory under /var/lib/agents holding agent.json, the secrets and the
# Matrix token, and one instance agent@<name>.service of the template.
# Everything agentctl needs to know about the host is rendered to
# /etc/agents/state.json so it stays a plain script with no Nix knowledge.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agentfleet;

  inherit (lib) mkOption mkIf types;

  # Fixed layout, exported in state.json.
  homeBase = "/srv/agents";
  stateDir = "/var/lib/agents";
  userPrefix = "agent-";
  nameRegex = "[a-z][a-z0-9-]{0,30}";
  maxUserLength = 32; # Linux user-name limit
  unitTemplate = "agent@%s.service";

  # Secrets agentctl prompts for on `add`; Hermes picks the provider from them.
  providerSecrets = [
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
  ];

  agentctl = pkgs.callPackage ../pkgs/agentctl { };

  sandbox = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "${homeBase}/%i" ];
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectProc = "invisible";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    # AF_NETLINK: getifaddrs(), which Python calls when binding.
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
    ];
    SystemCallArchitectures = "native";
    LockPersonality = true;
    UMask = "0077";
  };

  stateJson = builtins.toJSON {
    version = 3;
    inherit
      homeBase
      stateDir
      userPrefix
      nameRegex
      maxUserLength
      unitTemplate
      ;
    nologin = lib.getExe' pkgs.shadow "nologin";
    hostName = config.networking.hostName;
    secrets = providerSecrets;
    matrix = {
      inherit (cfg.matrix)
        serverName
        operator
        clientUrl
        stateDir
        ;
      ctl = "${cfg.matrix.package}/bin/agentfleet-matrix";
      synapseService = "matrix-synapse.service";
      reconcileService = "agentfleet-matrix.service";
    };
  };
in
{
  imports = [ ./matrix.nix ];

  options.services.agentfleet = {
    enable = lib.mkEnableOption "agentfleet: the Matrix server, the agent template and agentctl";

    hermesPackage = mkOption {
      type = types.package;
      description = "The Hermes Agent package. agentfleet.nixosModules.default sets it from the hermes-agent flake input.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.python3 pkgs.nodejs ]";
      description = "Extra packages on every agent's PATH, for Hermes's tools. bash, git, curl, jq, ripgrep and ssh are always there.";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.settings."50-agentfleet" = {
      ${homeBase}.d.mode = "0755";
      ${stateDir}.d.mode = "0700";
    };

    # One template; agentctl starts agent@<name>.service per agent.
    systemd.services."agent@" = {
      description = "agentfleet: Hermes agent %i";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "matrix-synapse.service"
        "agentfleet-matrix.service"
      ];
      # Requires the server (stopping it stops the agents) but only orders
      # after the reconciler, so a reconciler restart never restarts agents.
      requires = [ "matrix-synapse.service" ];
      path = [
        cfg.hermesPackage
        # Hermes runs its terminal tool through bash. Without one on PATH it
        # falls back to $SHELL, which systemd sets from the user database: the
        # agent's nologin, and every shell command fails with "This account is
        # currently not available".
        pkgs.bash
        pkgs.git
        pkgs.curl
        pkgs.jq
        pkgs.ripgrep
        pkgs.openssh
      ]
      ++ cfg.extraPackages;
      environment = {
        AGENT_NAME = "%i";
        HOME = "${homeBase}/%i";
        HERMES_HOME = "${homeBase}/%i/.hermes";
        # The account keeps nologin as its login shell; the agent's own shell
        # is bash. Hermes spawns background shells from $SHELL.
        SHELL = lib.getExe pkgs.bash;
        MATRIX_HOMESERVER = cfg.matrix.clientUrl;
        MATRIX_ALLOWED_USERS = cfg.matrix.operator;
        # Element encrypts the DMs it creates; optional mode joins them when
        # the bundled crypto libraries initialise and keeps plain rooms working.
        MATRIX_E2EE_MODE = "optional";
      };
      serviceConfig = {
        User = "${userPrefix}%i";
        Group = "${userPrefix}%i";
        WorkingDirectory = "${homeBase}/%i";
        ExecStart = "${lib.getExe' cfg.hermesPackage "hermes"} gateway";
        # secrets.env: provider keys (agentctl); environment.env: the agent's
        # non-secret variables (agentctl); matrix.env: token and user id
        # (reconciler). All root-only, read by systemd before dropping privileges.
        EnvironmentFile = [
          "${stateDir}/%i/secrets.env"
          "${stateDir}/%i/environment.env"
          "${stateDir}/%i/matrix.env"
        ];
        Restart = "on-failure";
        RestartSec = 5;
      }
      // sandbox;
    };

    # At boot, start every agent that exists. Instances of a template cannot
    # be enabled declaratively one by one, and agents are not declared anyway.
    systemd.services.agentfleet-agents = {
      description = "agentfleet: start all agents";
      wantedBy = [ "multi-user.target" ];
      after = [
        "agentfleet-matrix.service"
        "matrix-synapse.service"
      ];
      wants = [ "agentfleet-matrix.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${agentctl}/bin/agentctl start --all --quiet";
      };
    };

    environment.etc."agents/state.json" = {
      text = stateJson;
      mode = "0644";
    };

    environment.systemPackages = [ agentctl ];
  };
}
