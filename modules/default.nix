# agentfleet — core NixOS module.
#
# Declares `services.agentfleet`: a set of AI agents, each running as its own
# locked-down system user with its own home, systemd service and secrets
# file. Harness-specific knowledge (how to run Hermes,
# OpenClaw, Claude Code, ...) lives in modules/harnesses/*.nix, which register
# themselves under `services.agentfleet.harnesses.<name>`.
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
    hasPrefix
    removeSuffix
    escapeShellArg
    splitString
    ;

  # Also exported in state.json so agentctl validates names the same way.
  nameRegex = "[a-z][a-z0-9-]{0,30}";
  # Linux (and useradd) cap user names at 32 characters.
  maxUserLength = 32;

  ## ----- TOML registry -------------------------------------------------------
  # One file per agent: <registry.dir>/<name>.toml. Keys are snake_case in TOML
  # and mapped onto the camelCase submodule options below.
  tomlKeyMap = {
    harness = "harness";
    enable = "enable";
    autostart = "autostart";
    model = "model";
    packages = "packages";
    memory_max = "memoryMax";
    cpu_quota = "cpuQuota";
    environment = "environment";
    settings = "settings";
    description = "description";
    secrets_file = "secretsFile";
  };

  tomlFiles =
    if cfg.registry.dir == null then
      { }
    else
      filterAttrs (n: t: t == "regular" && hasSuffix ".toml" n) (builtins.readDir cfg.registry.dir);

  fromToml =
    fname: t:
    mapAttrs' (
      k: v:
      nameValuePair (tomlKeyMap.${k}
        or (throw "agentfleet: unknown key '${k}' in registry file ${fname} (known: ${concatStringsSep ", " (attrNames tomlKeyMap)})")
      ) v
    ) t;

  tomlAgents = mapAttrs' (
    fname: _:
    nameValuePair (removeSuffix ".toml" fname) (
      fromToml fname (builtins.fromTOML (builtins.readFile (cfg.registry.dir + "/${fname}")))
    )
  ) tomlFiles;

  ## ----- submodules ----------------------------------------------------------
  secretModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Environment variable name.";
      };
      required = mkOption {
        type = types.bool;
        default = false;
        description = "agentctl refuses to create an agent without this secret.";
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "Shown by agentctl when prompting.";
      };
    };
  };

  fileModule = types.submodule {
    options = {
      text = mkOption {
        type = types.str;
        description = "File contents.";
      };
      mode = mkOption {
        type = types.enum [
          "seed"
          "managed"
        ];
        default = "seed";
        description = ''
          `seed`: a real file, written only if it does not exist yet, so the
          harness and the agent may edit it afterwards. `managed`: a symlink
          into the Nix store, replaced on every activation; the agent cannot
          edit it and `perms` is ignored.
        '';
      };
      perms = mkOption {
        type = types.str;
        default = "0600";
        description = "Octal permissions.";
      };
    };
  };

  # Plain values only: they are rendered both into the unit and into
  # state.json for `systemd-run -p`.
  sandboxValue = types.oneOf [
    types.bool
    types.int
    types.str
    (types.listOf types.str)
  ];

  harnessModule = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        default = "";
        description = "One line shown by `agentctl harnesses`.";
      };
      package = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Main package of the harness, put on the agent's PATH.";
      };
      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Extra runtime dependencies on the agent's PATH.";
      };
      secrets = mkOption {
        type = types.listOf secretModule;
        default = [ ];
        description = "Secrets this harness understands; agentctl prompts for them on `add`.";
      };
      environment = mkOption {
        type = types.functionTo (types.attrsOf types.str);
        default = _: { };
        description = "agent -> non-secret environment for the service and the login shell.";
      };
      exec = mkOption {
        type = types.functionTo (types.nullOr types.str);
        default = _: null;
        description = ''
          agent -> command line for the long-running service, or null for an
          on-demand harness that is only used through `agentctl run`.
        '';
      };
      init = mkOption {
        type = types.functionTo types.lines;
        default = _: "";
        description = "agent -> shell script run once, as the agent user, on first start.";
      };
      files = mkOption {
        type = types.functionTo (types.attrsOf fileModule);
        default = _: { };
        description = "agent -> files to render into the agent's home (paths relative to home).";
      };
      sandbox = mkOption {
        type = types.functionTo (types.attrsOf sandboxValue);
        default = _: { };
        example = lib.literalExpression "_: { RestrictNamespaces = false; }";
        description = ''
          agent -> overrides for the built-in systemd sandbox. Applied to the
          service, the init unit and to `agentctl run`/`shell` alike. Use it
          when a harness needs something the defaults forbid, for example
          user namespaces for its own bubblewrap tool sandbox.
        '';
      };
      serviceConfig = mkOption {
        type = types.functionTo types.attrs;
        default = _: { };
        description = "agent -> extra systemd serviceConfig for the main service only.";
      };
      shellInit = mkOption {
        type = types.functionTo types.lines;
        default = _: "";
        description = "agent -> lines appended to the agent's seeded .bashrc.";
      };
    };
  };

  agentModule =
    { name, ... }:
    {
      options = {
        harness = mkOption {
          type = types.str;
          description = "Name of a harness under services.agentfleet.harnesses.";
        };
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "When false the agent is kept in the registry but nothing is deployed.";
        };
        autostart = mkOption {
          type = types.bool;
          default = true;
          description = "Start the agent's service at boot (ignored for on-demand harnesses).";
        };
        model = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default model id, passed to the harness in its own config format.";
        };
        packages = mkOption {
          type = types.listOf (types.either types.str types.package);
          default = [ ];
          description = "Extra packages on the agent's PATH. Strings are looked up in pkgs (dots allowed).";
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
          description = "Extra non-secret environment variables.";
        };
        settings = mkOption {
          type = types.attrs;
          default = { };
          description = ''
            Harness-specific settings, merged into the harness's own config
            file. Ends up in the world-readable Nix store: never put secrets
            here, use the secrets file.
          '';
        };
        description = mkOption {
          type = types.str;
          default = "";
          description = "Free text, shown by `agentctl list`.";
        };
        secretsFile = mkOption {
          type = types.str;
          default = "${cfg.stateDir}/${name}/secrets.env";
          defaultText = lib.literalExpression ''"''${services.agentfleet.stateDir}/<name>/secrets.env"'';
          description = ''
            KEY=VALUE file loaded into the service and into `agentctl run/shell`.
            Point this at a sops-nix or agenix secret to manage it declaratively.
            The file must exist; the default one is created empty.
          '';
        };
        extraServiceConfig = mkOption {
          type = types.attrs;
          default = { };
          description = "Extra systemd serviceConfig merged last into the main service.";
        };
      };
    };

  ## ----- resolution ----------------------------------------------------------
  # Nix-defined and registry agents, tagged with where they came from.
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
      hc = cfg.harnesses.${a.harness};
      user = "${cfg.userPrefix}${name}";
      home = "${cfg.homeBase}/${name}";
      self = {
        inherit name user home;
        group = user;
        inherit (a)
          harness
          model
          settings
          description
          autostart
          secretsFile
          ;
        stateDir = "${cfg.stateDir}/${name}";
        serviceName = "agent-${name}";
        initServiceName = "agent-${name}-init";
        harnessCfg = hc;
        raw = a;
        packages =
          (optional (hc.package != null) hc.package)
          ++ hc.packages
          ++ map resolvePkg a.packages
          ++ cfg.commonPackages;
        envVars = {
          HOME = home;
          AGENT_NAME = name;
          AGENT_HARNESS = a.harness;
        }
        // hc.environment self
        // a.environment;
        exec = hc.exec self;
      };
    in
    self;

  enabledAgents = filterAttrs (_: a: a.enable && cfg.harnesses ? ${a.harness}) allAgents;
  agents = mapAttrs resolve enabledAgents;
  serviceAgents = filterAttrs (_: ag: ag.exec != null) agents;

  profileOf =
    ag:
    pkgs.buildEnv {
      name = "agent-${ag.name}-profile";
      paths = ag.packages;
      ignoreCollisions = true;
    };

  shellEnvFile =
    ag:
    concatStringsSep "\n" (
      [ "# Generated by agentfleet for agent '${ag.name}'. Do not edit." ]
      ++ mapAttrsToList (k: v: "export ${k}=${escapeShellArg v}") ag.envVars
      ++ [
        "export PATH=${profileOf ag}/bin:/run/wrappers/bin:/run/current-system/sw/bin"
        ""
      ]
    );

  ## ----- rendered files in the agent's home -----------------------------------
  defaultFiles = ag: {
    ".bash_profile" = {
      mode = "managed";
      perms = "0644";
      text = ''
        # Managed by agentfleet. Put personal additions in ~/.bashrc.
        [ -r /etc/agents/${ag.name}.sh ] && . /etc/agents/${ag.name}.sh
        [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
      '';
    };
    ".bashrc" = {
      mode = "seed";
      perms = "0644";
      text = ''
        # Seeded by agentfleet; this file is yours to edit.
        [ -r /etc/agents/${ag.name}.sh ] && . /etc/agents/${ag.name}.sh
        ${ag.harnessCfg.shellInit ag}
      '';
    };
  };

  allFiles = ag: defaultFiles ag // ag.harnessCfg.files ag;

  # "a/b/c" -> [ "a" "a/b" ]
  parentDirs =
    rel:
    let
      parts = lib.init (splitString "/" rel);
    in
    lib.genList (i: concatStringsSep "/" (lib.take (i + 1) parts)) (builtins.length parts);

  ownedDir = ag: {
    d = {
      user = ag.user;
      group = ag.group;
      mode = "0750";
    };
  };

  # systemd-tmpfiles rules: directories, the default secrets file, and the
  # harness files. `C` copies only when the destination is missing (seed);
  # `L+` (re)points a symlink at the store every time (managed). Note that
  # `C+` would not replace an existing file.
  tmpfilesFor =
    ag:
    {
      ${ag.home} = ownedDir ag;
      ${ag.stateDir}.d = {
        user = "root";
        group = "root";
        mode = "0700";
      };
    }
    // optionalAttrs (ag.secretsFile == "${ag.stateDir}/secrets.env") {
      ${ag.secretsFile}.f = {
        user = "root";
        group = "root";
        mode = "0400";
      };
    }
    // lib.foldl' (acc: x: acc // x) { } (
      mapAttrsToList (
        rel: f:
        lib.genAttrs (map (d: "${ag.home}/${d}") (parentDirs rel)) (_: ownedDir ag)
        // {
          "${ag.home}/${rel}" =
            let
              src = toString (pkgs.writeText "agent-${ag.name}-${baseNameOf rel}" f.text);
            in
            if f.mode == "managed" then
              {
                "L+" = {
                  argument = src;
                  user = ag.user;
                  group = ag.group;
                };
              }
            else
              {
                C = {
                  argument = src;
                  user = ag.user;
                  group = ag.group;
                  mode = f.perms;
                };
              };
        }
      ) (allFiles ag)
    );

  ## ----- systemd -------------------------------------------------------------
  # One sandbox definition for everything that runs as the agent: the main
  # service, the init unit, and `agentctl run`/`shell` (via systemd-run, see
  # state.json below). Harnesses adjust it through their `sandbox` option.
  sandboxOf =
    ag:
    {
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectSystem = "strict";
      # ProtectHome hides /home entirely; only safe when agents live elsewhere.
      ProtectHome = !(hasPrefix "/home" cfg.homeBase);
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
      # Blocks user namespaces too, so a harness that sandboxes its own tool
      # calls with bwrap/unshare must set `sandbox = _: { RestrictNamespaces = false; }`.
      RestrictNamespaces = true;
      # AF_NETLINK: getifaddrs(), which Node and Python call when binding.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      SystemCallArchitectures = "native";
      LockPersonality = true;
      UMask = "0077";
    }
    // ag.harnessCfg.sandbox ag;

  # The same attrset as `Key=Value` strings for `systemd-run -p`.
  unitValue =
    v:
    if builtins.isBool v then
      (if v then "yes" else "no")
    else if builtins.isList v then
      concatStringsSep " " v
    else
      toString v;
  sandboxProps = ag: mapAttrsToList (k: v: "${k}=${unitValue v}") (sandboxOf ag);

  initService = ag: {
    description = "agentfleet: first-run initialisation for agent ${ag.name}";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "!${ag.home}/.agentfleet/initialized";
    path = ag.packages;
    environment = ag.envVars;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = ag.user;
      Group = ag.group;
      WorkingDirectory = ag.home;
      EnvironmentFile = ag.secretsFile;
    }
    // sandboxOf ag;
    script = ''
      set -euo pipefail
      ${ag.harnessCfg.init ag}
      mkdir -p "$HOME/.agentfleet"
      date -Is > "$HOME/.agentfleet/initialized"
    '';
  };

  mainService = ag: {
    description = "agentfleet: agent ${ag.name} (${ag.harness})";
    wantedBy = optional ag.autostart "multi-user.target";
    requires = [ "${ag.initServiceName}.service" ];
    wants = [ "network-online.target" ];
    after = [
      "${ag.initServiceName}.service"
      "network-online.target"
    ];
    path = ag.packages;
    environment = ag.envVars;
    serviceConfig = mkMerge [
      (
        {
          User = ag.user;
          Group = ag.group;
          WorkingDirectory = ag.home;
          ExecStart = ag.exec;
          EnvironmentFile = ag.secretsFile;
          Restart = "on-failure";
          RestartSec = 5;
        }
        // sandboxOf ag
        // optionalAttrs (ag.raw.memoryMax != null) { MemoryMax = ag.raw.memoryMax; }
        // optionalAttrs (ag.raw.cpuQuota != null) { CPUQuota = ag.raw.cpuQuota; }
      )
      (ag.harnessCfg.serviceConfig ag)
      ag.raw.extraServiceConfig
    ];
  };

  ## ----- state for agentctl --------------------------------------------------
  stateJson = builtins.toJSON {
    version = 1;
    inherit (cfg)
      homeBase
      stateDir
      userPrefix
      flakeDir
      rebuildCommand
      ;
    inherit nameRegex maxUserLength;
    registry = {
      hostPath = cfg.registry.hostPath;
      enabled = cfg.registry.dir != null;
    };
    harnesses = mapAttrs (_: h: {
      inherit (h) description secrets;
    }) cfg.harnesses;
    agents =
      mapAttrs (_: ag: {
        enabled = true;
        inherit (ag)
          user
          group
          home
          harness
          model
          description
          autostart
          secretsFile
          stateDir
          ;
        source = ag.raw.source;
        service = if ag.exec != null then "${ag.serviceName}.service" else null;
        initService = "${ag.initServiceName}.service";
        env = ag.envVars;
        path = "${profileOf ag}/bin";
        shell = "${pkgs.bashInteractive}/bin/bash";
        sandbox = sandboxProps ag;
      }) agents
      // mapAttrs (name: a: {
        enabled = false;
        inherit (a)
          harness
          model
          description
          source
          ;
        user = "${cfg.userPrefix}${name}";
        home = "${cfg.homeBase}/${name}";
        stateDir = "${cfg.stateDir}/${name}";
        secretsFile = a.secretsFile;
        service = null;
      }) (filterAttrs (_: a: !a.enable) allAgents);
  };

in
{
  options.services.agentfleet = {
    enable = mkOption {
      type = types.bool;
      default = cfg.registry.dir != null || allAgents != { };
      defaultText = lib.literalExpression "services.agentfleet.registry.dir != null || <any agent defined>";
      description = ''
        Install agentctl and deploy the agents declared below. On by default
        as soon as a registry directory is configured or any agent is defined.
      '';
    };

    agents = mkOption {
      type = types.attrsOf (types.submodule agentModule);
      default = { };
      description = "Agents defined in Nix. Merged with the TOML registry.";
    };

    harnesses = mkOption {
      type = types.attrsOf harnessModule;
      default = { };
      description = "Available harness recipes. Built-ins are registered by modules/harnesses.";
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
      description = "Checkout of the flake that configures this host.";
    };

    rebuildCommand = mkOption {
      type = types.str;
      default = "nixos-rebuild {action} --flake ${cfg.flakeDir}";
      defaultText = lib.literalExpression ''"nixos-rebuild {action} --flake ''${services.agentfleet.flakeDir}"'';
      description = ''
        Command agentctl runs to apply the registry. `{action}` is replaced by
        `switch` or `dry-activate`. Change it for colmena, deploy-rs, or a
        non-flake configuration.
      '';
    };

    homeBase = mkOption {
      type = types.str;
      default = "/srv/agents";
      description = "Agent homes are created at <homeBase>/<name>.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/agents";
      description = "Root-owned per-agent state: <stateDir>/<name>/secrets.env.";
    };

    userPrefix = mkOption {
      type = types.str;
      default = "agent-";
      description = "Unix user and group name prefix.";
    };

    commonPackages = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [
        git
        curl
        jq
        ripgrep
        openssh
      ];
      defaultText = lib.literalExpression "with pkgs; [ git curl jq ripgrep openssh ]";
      description = "Packages on every agent's PATH.";
    };

    cliPackage = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/agentctl { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/agentctl { }";
      description = "The agentctl package.";
    };

    installCli = mkOption {
      type = types.bool;
      default = true;
      description = "Put agentctl in environment.systemPackages.";
    };
  };

  config = mkMerge [
    { services.agentfleet.registry.agents = tomlAgents; }

    (mkIf cfg.enable {
      assertions =
        (mapAttrsToList (name: a: {
          assertion = builtins.match nameRegex name != null;
          message = "agentfleet: agent name '${name}' must match ${nameRegex}";
        }) allAgents)
        ++ (mapAttrsToList (name: a: {
          assertion = lib.stringLength "${cfg.userPrefix}${name}" <= maxUserLength;
          message = "agentfleet: user name '${cfg.userPrefix}${name}' is longer than ${toString maxUserLength} characters; shorten the agent name or userPrefix";
        }) allAgents)
        ++ (mapAttrsToList (name: a: {
          assertion = cfg.harnesses ? ${a.harness};
          message = "agentfleet: agent '${name}' uses unknown harness '${a.harness}' (available: ${concatStringsSep ", " (attrNames cfg.harnesses)})";
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
          shell = pkgs.bashInteractive;
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
        ${cfg.homeBase}.d.mode = "0755";
        ${cfg.stateDir}.d.mode = "0700";
      }
      // lib.foldl' (acc: x: acc // x) { } (mapAttrsToList (_: tmpfilesFor) agents);

      systemd.services =
        (mapAttrs' (_: ag: nameValuePair ag.initServiceName (initService ag)) agents)
        // (mapAttrs' (_: ag: nameValuePair ag.serviceName (mainService ag)) serviceAgents);

      environment.etc = {
        "agents/state.json" = {
          text = stateJson;
          mode = "0644";
        };
      }
      // mapAttrs' (
        _: ag:
        nameValuePair "agents/${ag.name}.sh" {
          text = shellEnvFile ag;
          mode = "0644";
        }
      ) agents;

      environment.systemPackages = optional cfg.installCli cfg.cliPackage;
    })
  ];
}
