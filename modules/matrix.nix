# agentfleet — the fleet's Matrix homeserver.
#
# Synapse runs with Postgres, speaking plain HTTP on loopback (for the agents)
# and optionally on a private address (for a reverse proxy on another
# machine). A root-side reconciler, agentfleet-matrix, runs after every
# activation and gives each agent an account and a fresh access token, sends
# a one-time introduction DM to the operator, and locks the accounts of
# removed agents. Only federation with the operator's homeserver needs the
# server to be reachable from outside: TLS, the four routes and .well-known
# are the reverse proxy's job (see docs/install.md).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agentfleet;
  m = cfg.matrix;

  inherit (lib)
    mkOption
    mkIf
    types
    mapAttrs
    ;

  stateDir = "/var/lib/agentfleet/matrix";
  synapseSecrets = "${stateDir}/synapse-secrets.yaml";

  spec = builtins.toJSON {
    inherit (m) clientUrl serverName operator;
    inherit stateDir;
    adminLocalpart = "agentfleet";
    hostName = config.networking.hostName;
    agents = mapAttrs (_: ag: {
      inherit (ag)
        localpart
        userId
        model
        description
        service
        ;
      envFile = ag.matrixEnvFile;
    }) cfg.resolvedAgents;
  };
in
{
  options.services.agentfleet.matrix = {
    serverName = mkOption {
      type = types.str;
      example = "matrix.example.org";
      description = ''
        The Matrix server name: the part after the colon in every user id
        (`@scout:matrix.example.org`). It is baked into the database and
        cannot be changed later without starting over.
      '';
    };

    operator = mkOption {
      type = types.str;
      example = "@alice:example.com";
      description = ''
        Your own Matrix user id, on your existing homeserver. Every agent
        allows this user to talk to it and sends it an introduction DM once
        provisioned.
      '';
    };

    publicBaseUrl = mkOption {
      type = types.str;
      default = "https://${m.serverName}";
      defaultText = lib.literalExpression ''"https://''${serverName}"'';
      description = "Where clients and other homeservers reach this server, via your reverse proxy.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 8008;
      description = "Port Synapse listens on (plain HTTP); point your reverse proxy here.";
    };

    listenAddresses = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1" ];
      example = [ "10.0.0.2" ];
      description = ''
        Addresses Synapse listens on. Loopback is always included for the
        agents and the reconciler. Add the address your reverse proxy reaches
        this host at when the proxy runs on another machine, and open
        `listenPort` to that machine only: the listener is unencrypted and
        exposes the admin API.
      '';
    };

    clientUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString m.listenPort}";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${listenPort}"'';
      internal = true;
      description = "URL agents and the reconciler use to reach the homeserver.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/agentfleet-matrix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/agentfleet-matrix { }";
      description = "The agentfleet-matrix reconciler.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "@[^:]+:.+" m.operator != null;
        message = "agentfleet: services.agentfleet.matrix.operator must look like @user:server";
      }
    ];

    environment.etc."agents/matrix.json" = {
      text = spec;
      mode = "0644";
    };

    environment.systemPackages = [ m.package ];

    systemd.tmpfiles.settings."50-agentfleet-matrix" = {
      ${stateDir}.d = {
        mode = "0750";
        group = "matrix-synapse";
      };
      "${stateDir}/agents".d.mode = "0700";
    };

    systemd.services.agentfleet-matrix = {
      description = "agentfleet: reconcile agents with the Matrix homeserver";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "matrix-synapse.service"
      ];
      requires = [ "matrix-synapse.service" ];
      restartTriggers = [ spec ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${m.package}/bin/agentfleet-matrix reconcile";
      };
    };

    services.matrix-synapse = {
      enable = true;
      extraConfigFiles = [ synapseSecrets ];
      settings = {
        server_name = m.serverName;
        public_baseurl = m.publicBaseUrl;
        listeners = [
          {
            port = m.listenPort;
            bind_addresses = lib.unique ([ "127.0.0.1" ] ++ m.listenAddresses);
            type = "http";
            tls = false;
            x_forwarded = true;
            resources = [
              {
                names = [
                  "client"
                  "federation"
                ];
                compress = false;
              }
            ];
          }
        ];
        enable_registration = false;
        report_stats = false;
        suppress_key_server_warning = true;
        allow_public_rooms_over_federation = false;
      };
    };

    services.postgresql.enable = true;

    # The registration shared secret Synapse and the reconciler share.
    systemd.services.agentfleet-matrix-secret = {
      description = "agentfleet: Synapse registration shared secret";
      before = [ "matrix-synapse.service" ];
      requiredBy = [ "matrix-synapse.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        umask 077
        if [ ! -s ${synapseSecrets} ]; then
          secret=$(head -c 48 /dev/urandom | base64 -w0 | tr -d '/+=')
          printf 'registration_shared_secret: "%s"\n' "$secret" > ${synapseSecrets}.tmp
          mv ${synapseSecrets}.tmp ${synapseSecrets}
        fi
        chown root:matrix-synapse ${synapseSecrets}
        chmod 0440 ${synapseSecrets}
      '';
    };

    # Synapse insists on a C-collated database, which ensureDatabases cannot
    # promise on an existing cluster; create it explicitly.
    systemd.services.agentfleet-matrix-db = {
      description = "agentfleet: Synapse database";
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
      before = [ "matrix-synapse.service" ];
      requiredBy = [ "matrix-synapse.service" ];
      path = [ config.services.postgresql.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        set -eu
        psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='matrix-synapse'" | grep -q 1 \
          || psql -c 'CREATE ROLE "matrix-synapse" LOGIN'
        psql -tAc "SELECT 1 FROM pg_database WHERE datname='matrix-synapse'" | grep -q 1 \
          || psql -c 'CREATE DATABASE "matrix-synapse" OWNER "matrix-synapse" TEMPLATE template0 LC_COLLATE "C" LC_CTYPE "C"'
      '';
    };
  };
}
