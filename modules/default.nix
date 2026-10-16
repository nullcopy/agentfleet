# agentfleet — a fleet of Hermes agents on one NixOS host, each its own
# locked-down system user, each with an account on the fleet's Matrix server
# (modules/matrix.nix).
#
# Agents come from two places and are merged:
#   1. `services.agentfleet.agents.<name> = { ... }`   — plain Nix
#   2. `services.agentfleet.registry.dir = ./agents;`  — one TOML file per
#      agent, which is what the `agentctl` CLI reads and writes.
#
# Everything agentctl needs at runtime is rendered to /etc/agents/state.json,
# so the CLI stays a dumb, portable script with no Nix knowledge.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agentfleet;

  inherit (lib)
    mkOption
    mkIf
    mkMerge
    types
    mapAttrs
    mapAttrs'
    mapAttrsToList
    nameValuePair
    filterAttrs
    attrNames
    concatStringsSep
    optional
    optionalString
    optionalAttrs
    hasSuffix
    removeSuffix
    splitString
    ;

  # Fixed layout. Also exported in state.json for agentctl.
  homeBase = "/srv/agents";
  stateDir = "/var/lib/agents";
  userPrefix = "agent-";
  nameRegex = "[a-z][a-z0-9-]{0,30}";
  maxUserLength = 32; # Linux user-name limit

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

  ## ----- TOML registry -------------------------------------------------------
  tomlKeyMap = {
    enable = "enable";
    model = "model";
    description = "description";
    packages = "packages";
    memory_max = "memoryMax";
    cpu_quota = "cpuQuota";
    environment = "environment";
    settings = "settings";
    matrix = "matrix";
  };
  matrixKeyMap = {
    localpart = "localpart";
  };

  mapKeys =
    keyMap: what: fname: t:
    mapAttrs' (
      k: v:
      nameValuePair (keyMap.${k}
        or (throw "agentfleet: unknown ${what}key '${k}' in registry file ${fname} (known: ${concatStringsSep ", " (attrNames keyMap)})")
      ) v
    ) t;

  fromToml =
    fname: t:
    mapAttrs (k: v: if k == "matrix" then mapKeys matrixKeyMap "[matrix] " fname v else v) (
      mapKeys tomlKeyMap "" fname t
    );

  tomlFiles =
    if cfg.registry.dir == null then
      { }
    else
      filterAttrs (n: t: t == "regular" && hasSuffix ".toml" n) (builtins.readDir cfg.registry.dir);

  tomlAgents = mapAttrs' (
    fname: _:
    nameValuePair (removeSuffix ".toml" fname) (
      fromToml fname (builtins.fromTOML (builtins.readFile (cfg.registry.dir + "/${fname}")))
    )
  ) tomlFiles;

  ## ----- agent submodule -----------------------------------------------------
  agentModule =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "When false the agent is kept in the registry but nothing is deployed.";
        };
        model = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "anthropic/claude-sonnet-5.5";
          description = "Hermes model id, seeded as model.default in config.yaml.";
        };
        description = mkOption {
          type = types.str;
          default = "";
          description = "Free text, shown by `agentctl list` and in the agent's introduction.";
        };
        packages = mkOption {
          type = types.listOf (types.either types.str types.package);
          default = [ ];
          description = "Extra packages on the agent's PATH (for Hermes's tools). Strings are looked up in pkgs.";
        };
        memoryMax = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "4G";
          description = "systemd MemoryMax for the service.";
        };
        cpuQuota = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "200%";
          description = "systemd CPUQuota for the service.";
        };
        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Extra non-secret environment variables (e.g. MATRIX_FREE_RESPONSE_ROOMS).";
        };
        settings = mkOption {
          type = types.attrs;
          default = { };
          description = ''
            Hermes config.yaml keys, seeded on first start. Ends up in the
            world-readable Nix store: never put secrets here.
          '';
        };
        matrix.localpart = mkOption {
          type = types.str;
          default = name;
          description = "Matrix user id local part: @<localpart>:<serverName>. Change it if the old id was deactivated.";
        };
      };
    };

  ## ----- resolution ----------------------------------------------------------
  allAgents =
    mapAttrs (_: a: a // { source = "nix"; }) cfg.agents
    // mapAttrs (_: a: a // { source = "toml"; }) cfg.registry.agents;

  clashingNames = lib.intersectLists (attrNames cfg.agents) (attrNames cfg.registry.agents);

  resolvePkg =
    p:
    if builtins.isString p then
      lib.attrByPath (splitString "." p) (throw "agentfleet: package '${p}' not found in pkgs") pkgs
    else
      p;

  resolve =
    name: a:
    let
      user = "${userPrefix}${name}";
      home = "${homeBase}/${name}";
    in
    {
      inherit name user home;
      group = user;
      inherit (a)
        model
        description
        settings
        source
        memoryMax
        cpuQuota
        ;
      stateDir = "${stateDir}/${name}";
      secretsFile = "${stateDir}/${name}/secrets.env";
      matrixEnvFile = "${stateDir}/${name}/matrix.env";
      localpart = a.matrix.localpart;
      userId = "@${a.matrix.localpart}:${cfg.matrix.serverName}";
      serviceName = "agent-${name}";
      initServiceName = "agent-${name}-init";
      packages = [
        cfg.hermesPackage
        pkgs.git
        pkgs.curl
        pkgs.jq
        pkgs.ripgrep
        pkgs.openssh
      ]
      ++ map resolvePkg a.packages;
      envVars = {
        HOME = home;
        AGENT_NAME = name;
        HERMES_HOME = "${home}/.hermes";
        MATRIX_HOMESERVER = cfg.matrix.clientUrl;
        MATRIX_USER_ID = "@${a.matrix.localpart}:${cfg.matrix.serverName}";
        MATRIX_ALLOWED_USERS = cfg.matrix.operator;
        # Element encrypts the DMs it creates; optional mode joins them when
        # the bundled crypto libraries initialise and keeps plain rooms working.
        MATRIX_E2EE_MODE = "optional";
      }
      // a.environment;
    };

  # The registry ends up in the world-readable Nix store and in git, so a
  # key that looks like a credential is refused; `key_env`-style names, which
  # only point at a variable, are fine.
  secretLike =
    k:
    let
      u = lib.toUpper k;
    in
    builtins.match ".*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL).*" u != null
    && builtins.match ".*_ENV" u == null;
  settingsLeaves =
    prefix: s:
    lib.concatLists (
      mapAttrsToList (
        k: v: if lib.isAttrs v then settingsLeaves "${prefix}${k}." v else [ "${prefix}${k}" ]
      ) s
    );
  leakyKeys =
    a:
    (lib.filter secretLike (attrNames a.environment))
    ++ (lib.filter (path: secretLike (lib.last (lib.splitString "." path))) (
      settingsLeaves "" a.settings
    ));

  enabledAgents = filterAttrs (_: a: a.enable) allAgents;
  agents = mapAttrs resolve enabledAgents;

  # Hermes rewrites config.yaml itself, so it is seeded once, never managed.
  # YAML is a superset of JSON.
  hermesConfig =
    ag:
    pkgs.writeText "agent-${ag.name}-config.yaml" (
      builtins.toJSON (
        lib.recursiveUpdate (optionalAttrs (ag.model != null) { model.default = ag.model; }) ag.settings
      )
    );

  tmpfilesFor = ag: {
    ${ag.home}.d = {
      user = ag.user;
      group = ag.group;
      mode = "0750";
    };
    "${ag.home}/.hermes".d = {
      user = ag.user;
      group = ag.group;
      mode = "0750";
    };
    "${ag.home}/.hermes/config.yaml".C = {
      argument = toString (hermesConfig ag);
      user = ag.user;
      group = ag.group;
      mode = "0600";
    };
    ${ag.stateDir}.d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    ${ag.secretsFile}.f = {
      user = "root";
      group = "root";
      mode = "0400";
    };
  };

  ## ----- systemd -------------------------------------------------------------
  sandbox = ag: {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ ag.home ];
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

  common = ag: {
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "agentfleet-matrix.service"
    ];
    requires = [ "agentfleet-matrix.service" ];
    path = ag.packages;
    environment = ag.envVars;
  };

  initService =
    ag:
    common ag
    // {
      description = "agentfleet: first-run initialisation for agent ${ag.name}";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!${ag.home}/.agentfleet/initialized";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = ag.user;
        Group = ag.group;
        WorkingDirectory = ag.home;
        EnvironmentFile = [
          ag.secretsFile
          ag.matrixEnvFile
        ];
      }
      // sandbox ag;
      script = ''
        set -euo pipefail
        mkdir -p "$HOME/.agentfleet"
        date -Is > "$HOME/.agentfleet/initialized"
      '';
    };

  mainService =
    ag:
    let
      c = common ag;
    in
    c
    // {
      description = "agentfleet: Hermes agent ${ag.name}";
      wantedBy = [ "multi-user.target" ];
      requires = c.requires ++ [ "${ag.initServiceName}.service" ];
      after = c.after ++ [ "${ag.initServiceName}.service" ];
      serviceConfig = {
        User = ag.user;
        Group = ag.group;
        WorkingDirectory = ag.home;
        ExecStart = "${lib.getExe' cfg.hermesPackage "hermes"} gateway";
        EnvironmentFile = [
          ag.secretsFile
          ag.matrixEnvFile
        ];
        Restart = "on-failure";
        RestartSec = 5;
      }
      // sandbox ag
      // optionalAttrs (ag.memoryMax != null) { MemoryMax = ag.memoryMax; }
      // optionalAttrs (ag.cpuQuota != null) { CPUQuota = ag.cpuQuota; };
    };

  ## ----- state for agentctl --------------------------------------------------
  stateJson = builtins.toJSON {
    version = 2;
    inherit
      homeBase
      stateDir
      userPrefix
      nameRegex
      maxUserLength
      ;
    inherit (cfg) flakeDir;
    inherit (cfg) rebuildCommand;
    registry = {
      hostPath = cfg.registry.hostPath;
      enabled = cfg.registry.dir != null;
    };
    secrets = providerSecrets;
    matrix = {
      inherit (cfg.matrix) serverName operator stateDir;
      ctl = "${cfg.matrix.package}/bin/agentfleet-matrix";
      synapseService = "matrix-synapse.service";
      reconcileService = "agentfleet-matrix.service";
    };
    agents =
      mapAttrs (_: ag: {
        enabled = true;
        inherit (ag)
          user
          home
          stateDir
          secretsFile
          source
          model
          description
          userId
          ;
        service = "${ag.serviceName}.service";
        initService = "${ag.initServiceName}.service";
      }) agents
      // mapAttrs (name: a: {
        enabled = false;
        inherit (a) source model description;
        user = "${userPrefix}${name}";
        home = "${homeBase}/${name}";
        stateDir = "${stateDir}/${name}";
        secretsFile = "${stateDir}/${name}/secrets.env";
        userId = "@${a.matrix.localpart}:${cfg.matrix.serverName}";
        service = null;
      }) (filterAttrs (_: a: !a.enable) allAgents);
  };

in
{
  imports = [ ./matrix.nix ];

  options.services.agentfleet = {
    enable = mkOption {
      type = types.bool;
      default = cfg.registry.dir != null || allAgents != { };
      defaultText = lib.literalExpression "services.agentfleet.registry.dir != null || <any agent defined>";
      description = "Run the fleet: Matrix server, agentctl, and the agents declared below.";
    };

    agents = mkOption {
      type = types.attrsOf (types.submodule agentModule);
      default = { };
      description = "Agents defined in Nix. Merged with the TOML registry.";
    };

    registry = {
      dir = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = lib.literalExpression "./agents";
        description = ''
          Directory of <name>.toml files, one per agent, evaluated at build
          time. Must live inside your flake so it is copied to the store.
        '';
      };
      hostPath = mkOption {
        type = types.str;
        default = "${cfg.flakeDir}/agents";
        defaultText = lib.literalExpression ''"''${services.agentfleet.flakeDir}/agents"'';
        description = "Where that same directory lives on disk, so agentctl can write to it.";
      };
      agents = mkOption {
        type = types.attrsOf (types.submodule agentModule);
        default = { };
        internal = true;
        description = "Agents parsed from registry.dir; set by this module.";
      };
    };

    flakeDir = mkOption {
      type = types.str;
      default = "/etc/nixos";
      description = "Checkout of the flake that configures this host; agentctl runs `nixos-rebuild switch --flake` on it.";
    };

    rebuildCommand = mkOption {
      type = types.str;
      default = "nixos-rebuild switch --flake ${cfg.flakeDir}";
      defaultText = lib.literalExpression ''"nixos-rebuild switch --flake ''${services.agentfleet.flakeDir}"'';
      internal = true;
      description = "What agentctl add/rm run after changing the registry (overridden by the VM test).";
    };

    hermesPackage = mkOption {
      type = types.package;
      description = "The Hermes Agent package. agentfleet.nixosModules.default sets it from the hermes-agent flake input.";
    };

    resolvedAgents = mkOption {
      type = types.attrs;
      default = { };
      internal = true;
      description = "Enabled agents after resolution, for matrix.nix.";
    };
  };

  config = mkMerge [
    { services.agentfleet.registry.agents = tomlAgents; }

    (mkIf cfg.enable {
      services.agentfleet.resolvedAgents = mapAttrs (_: ag: {
        inherit (ag)
          name
          localpart
          userId
          matrixEnvFile
          model
          description
          ;
        service = "${ag.serviceName}.service";
      }) agents;

      assertions =
        (mapAttrsToList (name: a: {
          assertion = builtins.match nameRegex name != null;
          message = "agentfleet: agent name '${name}' must match ${nameRegex}";
        }) allAgents)
        ++ (mapAttrsToList (name: a: {
          assertion = lib.stringLength "${userPrefix}${name}" <= maxUserLength;
          message = "agentfleet: user name '${userPrefix}${name}' is longer than ${toString maxUserLength} characters; shorten the agent name";
        }) allAgents)
        ++ (mapAttrsToList (name: a: {
          assertion = builtins.match "[a-z0-9._=/+-]+" a.matrix.localpart != null;
          message = "agentfleet: agent '${name}': matrix.localpart '${a.matrix.localpart}' is not a valid Matrix localpart";
        }) allAgents)
        ++ (mapAttrsToList (name: a: {
          assertion = leakyKeys a == [ ];
          message = "agentfleet: agent '${name}': ${concatStringsSep ", " (leakyKeys a)} look(s) like a secret. The registry is copied into the world-readable Nix store and committed to git; use `agentctl secrets set ${name} <NAME>` instead";
        }) allAgents)
        ++ [
          {
            assertion = clashingNames == [ ];
            message = "agentfleet: agent(s) ${concatStringsSep ", " clashingNames} are defined both in Nix and in the TOML registry; keep one";
          }
        ];

      users.users = mapAttrs' (
        _: ag:
        nameValuePair ag.user {
          isSystemUser = true;
          group = ag.group;
          home = ag.home;
          createHome = false;
          # GECOS field: no colons or newlines allowed.
          description =
            "agentfleet agent ${ag.name}"
            + optionalString (ag.description != "") (
              " - " + lib.replaceStrings [ ":" "\n" ] [ ";" " " ] ag.description
            );
        }
      ) agents;

      users.groups = mapAttrs' (_: ag: nameValuePair ag.group { }) agents;

      systemd.tmpfiles.settings."50-agentfleet" = {
        ${homeBase}.d.mode = "0755";
        ${stateDir}.d.mode = "0700";
      }
      // lib.foldl' (acc: x: acc // x) { } (mapAttrsToList (_: tmpfilesFor) agents);

      systemd.services =
        (mapAttrs' (_: ag: nameValuePair ag.initServiceName (initService ag)) agents)
        // (mapAttrs' (_: ag: nameValuePair ag.serviceName (mainService ag)) agents);

      environment.etc."agents/state.json" = {
        text = stateJson;
        mode = "0644";
      };

      environment.systemPackages = [ (pkgs.callPackage ../pkgs/agentctl { }) ];
    })
  ];
}
