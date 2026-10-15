# NixOS VM test: real Synapse, a stub `hermes` so nothing heavy is built, a
# local operator account created through Synapse's admin API.
# Run with: nix build .#checks.x86_64-linux.vm   (needs KVM)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "agentfleet";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.agentfleet = {
        flakeDir = "/root/flake";
        rebuildCommand = "echo would-run nixos-rebuild";
        registry.dir = ./vm-registry;
        registry.hostPath = "/root/flake/agents";
        # Stands in for Hermes: proves the unit, environment and token wiring
        # without building the real package.
        hermesPackage = pkgs.writeShellScriptBin "hermes" ''
          env | grep -E '^(MATRIX|HERMES|AGENT|ANTHROPIC)_' | sort > "$HOME/env-seen"
          exec sleep infinity
        '';

        matrix = {
          serverName = "localhost";
          publicBaseUrl = "http://localhost:8008";
          operator = "@op:localhost";
        };

        agents.sleeper = {
          model = "test/model";
          description = "test agent";
          environment.GREETING = "hello";
        };
      };
    };

  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("matrix-synapse.service")
    machine.wait_for_unit("agentfleet-matrix.service")

    # users, homes, perms
    machine.succeed("id agent-sleeper && id agent-fromtoml")
    assert machine.succeed("stat -c %U:%a /srv/agents/sleeper").strip() == "agent-sleeper:750"
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/secrets.env").strip() == "root:400"
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/matrix.env").strip() == "root:400"
    assert machine.succeed("stat -c %U:%a /srv/agents/sleeper/.hermes/config.yaml").strip() == "agent-sleeper:600"
    assert json.loads(machine.succeed("cat /srv/agents/sleeper/.hermes/config.yaml"))["model"]["default"] == "test/model"

    # services and the environment the (stub) gateway saw
    machine.wait_for_unit("agent-sleeper.service")
    machine.wait_for_unit("agent-fromtoml.service")
    machine.succeed("test -f /srv/agents/sleeper/.agentfleet/initialized")
    machine.wait_until_succeeds("test -s /srv/agents/sleeper/env-seen")
    env = dict(l.split("=", 1) for l in machine.succeed("cat /srv/agents/sleeper/env-seen").splitlines())
    assert env["MATRIX_USER_ID"] == "@sleeper:localhost", env
    assert env["MATRIX_ALLOWED_USERS"] == "@op:localhost", env
    assert env["MATRIX_HOMESERVER"] == "http://127.0.0.1:8008", env
    assert env["MATRIX_DEVICE_ID"] == "AGENTFLEET" and env["MATRIX_ACCESS_TOKEN"], env
    assert env["HERMES_HOME"] == "/srv/agents/sleeper/.hermes", env
    # sandbox properties made it into the unit
    assert machine.succeed("systemctl show agent-sleeper.service -p ProtectSystem").strip() == "ProtectSystem=strict"

    # state.json and agentctl
    state = json.loads(machine.succeed("cat /etc/agents/state.json"))
    assert set(state["agents"]) == {"sleeper", "fromtoml"}, state["agents"].keys()
    assert state["agents"]["fromtoml"]["source"] == "toml"
    assert state["agents"]["sleeper"]["userId"] == "@sleeper:localhost"
    out = machine.succeed("agentctl list")
    assert "sleeper" in out and "active" in out and "@fromtoml:localhost" in out, out
    out = machine.succeed("agentctl matrix status")
    assert "@sleeper:localhost" in out and "active" in out, out

    # secrets: quoting round trip, and the restart hands the key to the gateway
    machine.succeed("agentctl secrets set sleeper ANTHROPIC_API_KEY='p@$s\"w'")
    assert machine.succeed("agentctl secrets list sleeper").split() == ["ANTHROPIC_API_KEY"]
    machine.wait_until_succeeds("grep -qF 'ANTHROPIC_API_KEY=p@$s\"w' /srv/agents/sleeper/env-seen")

    # the agent's token works against the homeserver
    tok = machine.succeed("awk -F'\\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    who = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {tok}' http://127.0.0.1:8008/_matrix/client/v3/account/whoami"))
    assert who["user_id"] == "@sleeper:localhost" and who["device_id"] == "AGENTFLEET", who

    # the operator did not exist at boot, so create one via the admin API and re-introduce
    admin = json.loads(machine.succeed("cat /var/lib/agentfleet/matrix/admin.json"))["access_token"]
    machine.succeed(f"curl -sf -X PUT -H 'Authorization: Bearer {admin}' -d '{{\\"password\\":\\"oppass\\",\\"admin\\":false}}' 'http://127.0.0.1:8008/_synapse/admin/v2/users/@op:localhost'")
    op = json.loads(machine.succeed("curl -sf -X POST -d '{\\"type\\":\\"m.login.password\\",\\"identifier\\":{\\"type\\":\\"m.id.user\\",\\"user\\":\\"op\\"},\\"password\\":\\"oppass\\"}' http://127.0.0.1:8008/_matrix/client/v3/login"))["access_token"]
    machine.succeed("agentctl matrix introduce sleeper")
    sync = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op}' 'http://127.0.0.1:8008/_matrix/client/v3/sync?timeout=0'"))
    invites = sync.get("rooms", {}).get("invite", {})
    assert len(invites) >= 1, invites
    room = next(iter(invites))
    machine.succeed(f"curl -sf -X POST -H 'Authorization: Bearer {op}' -d '{{}}' http://127.0.0.1:8008/_matrix/client/v3/join/{room}")
    msgs = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op}' 'http://127.0.0.1:8008/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=10'"))
    bodies = [e["content"].get("body", "") for e in msgs["chunk"] if e["type"] == "m.room.message"]
    assert any("I'm sleeper, a Hermes agent" in b for b in bodies), bodies

    # reconcile is idempotent; rotation invalidates the old token
    machine.succeed("systemctl restart agentfleet-matrix.service")
    assert tok == machine.succeed("awk -F'\\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    machine.succeed("agentctl matrix rotate-token sleeper")
    machine.fail(f"curl -sf -H 'Authorization: Bearer {tok}' http://127.0.0.1:8008/_matrix/client/v3/account/whoami")
    machine.fail("agentctl matrix deactivate sleeper")  # still declared

    # agentctl add / rm against a git-tracked registry (rebuild is a no-op here)
    machine.succeed("mkdir -p /root/flake/agents && git -C /root/flake init -q")
    out = machine.succeed("agentctl add demo --no-prompt --model test/m --env A=1 --memory-max 1G --set model.provider=anthropic")
    assert "would-run nixos-rebuild" in out, out
    toml = machine.succeed("cat /root/flake/agents/demo.toml")
    assert 'model = "test/m"' in toml and "[settings.model]" in toml and 'memory_max = "1G"' in toml, toml
    machine.succeed("git -C /root/flake ls-files --error-unmatch agents/demo.toml")
    machine.succeed("agentctl rm demo --yes --no-rebuild")
    machine.fail("test -e /root/flake/agents/demo.toml")
    machine.fail("agentctl rm sleeper --yes")  # defined in Nix, not removable
  '';
}
