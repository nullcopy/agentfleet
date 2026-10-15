# agentfleet — built-in Matrix homeserver for the fleet.
#
# `services.agentfleet.matrix.enable` runs Synapse on loopback (with Postgres)
# and a root-side reconciler, agentfleet-matrix, that after every activation
# gives each Matrix-enabled agent an account and a fresh access token, sends a
# one-time introduction DM to the operator, and locks accounts of removed
# agents. Agents reach Synapse over 127.0.0.1; only federation with other
# homeservers needs the host to be reachable from outside, which is left to
# the admin (reverse proxy + TLS + .well-known, see docs/install.md).
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
    mkMerge
    types
    optional
    filterAttrs
    mapAttrs
    ;

  matrixAgents = filterAttrs (_: ag: ag.matrix.enable) cfg.resolvedAgents;

  spec = builtins.toJSON {
    inherit (m)
      clientUrl
      serverName
      operator
      stateDir
      adminLocalpart
      ;
    hostName = config.networking.hostName;
    agents = mapAttrs (_: ag: {
      inherit (ag.matrix)
        localpart
        userId
        envFile
        introduce
        ;
      inherit (ag)
        harness
        model
        description
        service
        ;
    }) matrixAgents;
  };

  synapseSecrets = "${m.stateDir}/synapse-secrets.yaml";
in
{
  options.services.agentfleet.matrix = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Run a Matrix homeserver for the fleet and give every agent an account on it.";
    };

    serverName = mkOption {
      type = types.str;
      example = "matrix.arx9.net";
      description = ''
        The Matrix server name: the part after the colon in every user id
        (`@scout:matrix.arx9.net`). It is baked into the database and cannot be
        changed later without starting over.
      '';
    };

    publicBaseUrl = mkOption {
      type = types.str;
      default = "https://${m.serverName}";
      defaultText = lib.literalExpression ''"https://''${serverName}"'';
      description = "Where clients and other homeservers reach this server, via your reverse proxy.";
    };

    operator = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "@nullcopy:4d2.org";
      description = ''
        Your own Matrix user. Every agent allows this user to talk to it and
        sends it an introduction DM once provisioned. Can be on any homeserver
        (requires federation) or on this one (see `agentfleet matrix register-user`).
      '';
    };

    extraAllowedUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Further Matrix users allowed to talk to every agent.";
    };

    listenPort = mkOption {
      type = types.port;
      default = 8008;
      description = "Loopback port Synapse listens on; point your reverse proxy here.";
    };

    clientUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString m.listenPort}";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${listenPort}"'';
      description = "URL agents and the reconciler use to reach the homeserver.";
    };

    manageSynapse = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Configure Synapse and Postgres on this host. Set to false to use a
        homeserver you run yourself; then provide `clientUrl` and put its
        `registration_shared_secret: "..."` line in
        `<stateDir>/synapse-secrets.yaml`.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/agentfleet/matrix";
      description = "Root-only state: shared secret, admin token, per-agent account records.";
    };

    adminLocalpart = mkOption {
      type = types.str;
      default = "agentfleet";
      description = "Local part of the admin account the reconciler creates for itself.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/agentfleet-matrix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/agentfleet-matrix { }";
      description = "The agentfleet-matrix reconciler.";
    };
  };

  config = mkIf (cfg.enable && m.enable) (mkMerge [
    {
      assertions = [
        {
          assertion = m.operator == null || builtins.match "@[^:]+:.+" m.operator != null;
          message = "agentfleet: services.agentfleet.matrix.operator must look like @user:server";
        }
      ];

      environment.etc."agents/matrix.json" = {
        text = spec;
        mode = "0644";
      };

      environment.systemPackages = [ m.package ];

      systemd.tmpfiles.settings."50-agentfleet-matrix" = {
        ${m.stateDir}.d = {
          mode = if m.manageSynapse then "0750" else "0700";
          group = if m.manageSynapse then "matrix-synapse" else "root";
        };
        "${m.stateDir}/agents".d.mode = "0700";
      };

      systemd.services.agentfleet-matrix = {
        description = "agentfleet: reconcile agents with the Matrix homeserver";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ] ++ optional m.manageSynapse "matrix-synapse.service";
        requires = optional m.manageSynapse "matrix-synapse.service";
        restartTriggers = [ spec ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${m.package}/bin/agentfleet-matrix reconcile";
        };
      };
    }

    (mkIf m.manageSynapse {
      services.matrix-synapse = {
        enable = true;
        extraConfigFiles = [ synapseSecrets ];
        settings = {
          server_name = m.serverName;
          public_baseurl = m.publicBaseUrl;
          listeners = [
            {
              port = m.listenPort;
              bind_addresses = [ "127.0.0.1" ];
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
    })
  ]);
}
