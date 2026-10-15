# The fleet's Matrix server

With `services.agentfleet.matrix.enable = true` the host runs its own Matrix
homeserver and every Hermes agent gets an account on it, a stable device, an
access token it never sees in plain text, and a one-time introduction DM to
you. Removing the agent locks the account; purging it deactivates it.

Agents talk to the homeserver over loopback, so nothing here needs to be
reachable from outside. Public reachability is only required for federation,
which is what lets your own account on another homeserver talk to the agents.
That part is yours; the last section shows what is expected of the reverse
proxy.

## Configuration

```nix
services.agentfleet.matrix = {
  enable = true;
  serverName = "matrix.arx9.net";        # user ids become @<agent>:matrix.arx9.net
  publicBaseUrl = "https://matrix.arx9.net";
  operator = "@nullcopy:4d2.org";        # you: allowed to talk to every agent, receives the intros
};
```

`serverName` is permanent. It is written into every user id and into the
database, and Synapse refuses to start if it changes. Pick it before the first
rebuild.

Per agent, nothing is required. The defaults give a Hermes agent `scout` the
account `@scout:matrix.arx9.net`. Overrides, in Nix or in the TOML registry:

```toml
[matrix]
enable = true                       # false: no account for this agent (agentctl add --no-matrix)
localpart = "scout2"                # if @scout was deactivated earlier
allowed_users = ["@friend:example.org"]
introduce = true
```

## What the host runs

| unit | role |
|---|---|
| `matrix-synapse.service` | Synapse on `127.0.0.1:8008`, Postgres-backed, registration closed |
| `agentfleet-matrix-secret.service` | generates the registration shared secret Synapse and the reconciler share |
| `agentfleet-matrix-db.service` | creates the C-collated Postgres database Synapse insists on |
| `agentfleet-matrix.service` | the reconciler, run after every activation |

The reconciler (`agentfleet-matrix`, also reachable as `agentctl matrix`) reads
`/etc/agents/matrix.json`, which the module renders, and keeps the homeserver
in step with it:

1. Creates an admin account `@agentfleet:<serverName>` on first run and keeps
   its token in `/var/lib/agentfleet/matrix/admin.json`.
2. For each Matrix-enabled agent: creates the account if missing, unlocks it
   if it was locked, lifts Synapse's message rate limit for it, sets a fresh
   password, logs in with the fixed device id `AGENTFLEET`, and writes the
   token to `/var/lib/agents/<name>/matrix.env` (root, 0400). The agent's
   units and `agentctl run`/`shell` load that file after the regular secrets
   file. A running service is restarted when its token changed.
3. Sends the introduction: a private room created by the agent, you invited,
   one message naming the agent, its harness, model and description. If the
   invite cannot be delivered yet, typically because federation is not set
   up, it is retried on every run and by `agentctl matrix introduce <name>`.
4. Locks the account and logs out every device of any agent it provisioned
   earlier that is no longer declared.

The agent's environment carries `MATRIX_HOMESERVER`, `MATRIX_USER_ID` and
`MATRIX_ALLOWED_USERS` (operator, `extraAllowedUsers`, the agent's own list)
from Nix, and `MATRIX_ACCESS_TOKEN` and `MATRIX_DEVICE_ID` from the token
file. Hermes reads exactly these. The Hermes recipe also sets
`MATRIX_E2EE_MODE=optional`, so encrypted DMs created from Element work and
unencrypted rooms keep working if the crypto store cannot initialise.

## Day to day

```
agentctl matrix status                 homeserver, admin, per-agent account state
agentctl matrix introduce <name>       resend the introduction DM
agentctl matrix rotate-token <name>    log out every session, issue a new token, restart the agent
agentctl matrix deactivate <name>      after `agentctl rm`: deactivate the account for good
agentctl matrix register-user <local>  a human account on this server (prints its token)
```

Removal semantics:

- `agentctl rm scout` locks `@scout:matrix.arx9.net` and logs it out. Adding
  an agent named `scout` again unlocks the same account.
- `agentctl rm scout --purge` additionally deactivates it. Synapse never lets a
  deactivated id be registered again, so a later `scout` needs
  `matrix.localpart = "scout2"` (the reconciler tells you).

If you would rather have your own account on the agents' server than federate
from elsewhere, create it with `agentctl matrix register-user nullcopy`, log in
to Element with the printed password, and set `operator = "@nullcopy:matrix.arx9.net"`.
No reverse proxy is needed then for talking to agents, only for using the
account from the internet.

## Reverse proxy and federation (yours to set up)

Synapse listens on `127.0.0.1:8008` for both the client and the federation
API, with `x_forwarded` on. For `serverName = "matrix.arx9.net"` other
homeservers look up `https://matrix.arx9.net/.well-known/matrix/server`; serve
it from the same host and port 443 does federation too, with no 8448 needed.
A reference nginx configuration, not managed by agentfleet:

```nix
services.nginx.virtualHosts."matrix.arx9.net" = {
  enableACME = true;
  forceSSL = true;
  locations."/_matrix".proxyPass = "http://127.0.0.1:8008";
  locations."/_synapse/client".proxyPass = "http://127.0.0.1:8008";
  locations."= /.well-known/matrix/server".extraConfig = ''
    default_type application/json;
    return 200 '{"m.server": "matrix.arx9.net:443"}';
  '';
  locations."= /.well-known/matrix/client".extraConfig = ''
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.homeserver": {"base_url": "https://matrix.arx9.net"}}';
  '';
  extraConfig = "client_max_body_size 50M;";
};
```

Check federation from outside with the
[Matrix Federation Tester](https://federationtester.matrix.org/#matrix.arx9.net).
Until it passes, `agentctl matrix status` shows agents as active but not
introduced, and `agentctl logs` of the reconciler says the invite could not be
delivered.

## Using a homeserver you already run

Set `manageSynapse = false`, point `clientUrl` at it, and put its
`registration_shared_secret: "..."` line in
`/var/lib/agentfleet/matrix/synapse-secrets.yaml` (root, 0600). The
reconciler needs the Synapse admin API, so this works with Synapse only.
