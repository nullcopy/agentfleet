# NixOS VM test: real Synapse, real useradd, the agent@ template, a stub
# `hermes` so nothing heavy is built, a local operator account created
# through Synapse's admin API, and a reboot to prove agents come back.
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
        enable = true;
        # Stands in for Hermes: proves the unit, environment and token wiring
        # without building the real package.
        hermesPackage = pkgs.writeShellScriptBin "hermes" ''
          env | grep -E '^(MATRIX|HERMES|AGENT|ANTHROPIC|GREETING)' | sort > "$HOME/env-seen"
          exec sleep infinity
        '';
        matrix = {
          serverName = "localhost";
          publicBaseUrl = "http://localhost:8008";
          operator = "@op:localhost";
        };
      };
    };

  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("matrix-synapse.service")
    machine.wait_for_unit("agentfleet-matrix.service")
    assert "no agents" in machine.succeed("agentctl list")

    # the operator must exist for the invite to work; create one via the admin API
    admin = json.loads(machine.succeed("cat /var/lib/agentfleet/matrix/admin.json"))["access_token"]
    machine.succeed(f"curl -sf -X PUT -H 'Authorization: Bearer {admin}' -d '{{\\"password\\":\\"oppass\\",\\"admin\\":false}}' 'http://127.0.0.1:8008/_synapse/admin/v2/users/@op:localhost'")
    op = json.loads(machine.succeed("curl -sf -X POST -d '{\\"type\\":\\"m.login.password\\",\\"identifier\\":{\\"type\\":\\"m.id.user\\",\\"user\\":\\"op\\"},\\"password\\":\\"oppass\\"}' http://127.0.0.1:8008/_matrix/client/v3/login"))["access_token"]

    # add: no rebuild, agent up, introduced
    out = machine.succeed("agentctl add sleeper --no-prompt --model test/model --description 'test agent' --env GREETING=hello --secret ANTHROPIC_API_KEY='p@$s\"w' --set model.provider=anthropic")
    assert "has invited @op:localhost" in out, out
    machine.succeed("id agent-sleeper")
    assert machine.succeed("stat -c %U:%a /srv/agents/sleeper").strip() == "agent-sleeper:750"
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/secrets.env").strip() == "root:400"
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/matrix.env").strip() == "root:400"
    assert machine.succeed("stat -c %U:%a /srv/agents/sleeper/.hermes/config.yaml").strip() == "agent-sleeper:600"
    cfg = json.loads(machine.succeed("cat /srv/agents/sleeper/.hermes/config.yaml"))
    assert cfg["model"] == {"default": "test/model", "provider": "anthropic"}, cfg
    machine.wait_for_unit("agent@sleeper.service")
    machine.wait_until_succeeds("test -s /srv/agents/sleeper/env-seen")
    env = dict(l.split("=", 1) for l in machine.succeed("cat /srv/agents/sleeper/env-seen").splitlines())
    assert env["MATRIX_USER_ID"] == "@sleeper:localhost", env
    assert env["MATRIX_ALLOWED_USERS"] == "@op:localhost", env
    assert env["MATRIX_HOMESERVER"] == "http://127.0.0.1:8008", env
    assert env["MATRIX_DEVICE_ID"] == "AGENTFLEET" and env["MATRIX_ACCESS_TOKEN"], env
    assert env["HERMES_HOME"] == "/srv/agents/sleeper/.hermes", env
    assert env["GREETING"] == "hello" and env["ANTHROPIC_API_KEY"] == 'p@$s"w', env
    assert machine.succeed("systemctl show agent@sleeper.service -p ProtectSystem").strip() == "ProtectSystem=strict"
    assert machine.succeed("systemctl show agent@sleeper.service -p User").strip() == "User=agent-sleeper"

    # the operator got the invite and the greeting
    sync = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op}' 'http://127.0.0.1:8008/_matrix/client/v3/sync?timeout=0'"))
    invites = sync.get("rooms", {}).get("invite", {})
    assert len(invites) == 1, invites
    room = next(iter(invites))
    machine.succeed(f"curl -sf -X POST -H 'Authorization: Bearer {op}' -d '{{}}' http://127.0.0.1:8008/_matrix/client/v3/join/{room}")
    msgs = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op}' 'http://127.0.0.1:8008/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=10'"))
    bodies = [e["content"].get("body", "") for e in msgs["chunk"] if e["type"] == "m.room.message"]
    assert any("I'm sleeper, a Hermes agent" in b for b in bodies), bodies

    # list / status / secrets round trip
    out = machine.succeed("agentctl list")
    assert "sleeper" in out and "active" in out and "@sleeper:localhost" in out, out
    out = machine.succeed("agentctl matrix status")
    assert "@sleeper:localhost" in out and "active" in out, out
    machine.succeed("agentctl secrets set sleeper OPENAI_API_KEY=x")
    assert machine.succeed("agentctl secrets list sleeper").split() == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]

    # a second agent does not restart the first; limits land as a drop-in
    started = machine.succeed("systemctl show agent@sleeper.service -p ExecMainStartTimestampMonotonic").strip()
    machine.succeed("agentctl add demo --no-prompt --model test/m --memory-max 1G")
    machine.wait_for_unit("agent@demo.service")
    assert machine.succeed("systemctl show agent@sleeper.service -p ExecMainStartTimestampMonotonic").strip() == started
    assert machine.succeed("systemctl show agent@demo.service -p MemoryMax").strip() == "MemoryMax=1073741824"
    assert machine.succeed("systemctl show agent@sleeper.service -p MemoryMax").strip() == "MemoryMax=infinity"

    # reconcile is idempotent; rotation invalidates the old token
    tok = env["MATRIX_ACCESS_TOKEN"]
    machine.succeed("systemctl restart agentfleet-matrix.service")
    assert tok == machine.succeed("awk -F'\\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    machine.succeed("agentctl matrix rotate-token sleeper")
    machine.fail(f"curl -sf -H 'Authorization: Bearer {tok}' http://127.0.0.1:8008/_matrix/client/v3/account/whoami")

    # rm keeps everything and locks; add resumes the same account and room
    machine.succeed("agentctl rm demo --yes")
    assert "removed" in machine.succeed("agentctl list")
    machine.succeed("id agent-demo && test -d /srv/agents/demo")
    assert "locked" in machine.succeed("agentctl matrix status")
    rec = json.loads(machine.succeed("cat /var/lib/agentfleet/matrix/agents/demo.json"))
    machine.succeed("agentctl add demo --no-prompt")
    machine.wait_for_unit("agent@demo.service")
    rec2 = json.loads(machine.succeed("cat /var/lib/agentfleet/matrix/agents/demo.json"))
    assert rec2["introduced_room"] == rec["introduced_room"] and rec2["state"] == "active"

    # purge retires the name
    machine.succeed("agentctl rm demo --purge --yes")
    machine.fail("id agent-demo")
    machine.fail("test -e /srv/agents/demo -o -e /var/lib/agents/demo")
    assert "purged" in machine.succeed("agentctl matrix status")
    machine.fail("agentctl add demo --no-prompt")

    # fleet and server lifecycle
    machine.succeed("agentctl stop --all")
    assert machine.succeed("systemctl is-active agent@sleeper.service || true").strip() == "inactive"
    machine.succeed("agentctl start --all")
    machine.wait_for_unit("agent@sleeper.service")
    machine.succeed("agentctl matrix stop")
    assert machine.succeed("systemctl is-active agent@sleeper.service || true").strip() == "inactive"
    machine.succeed("agentctl matrix start")
    machine.wait_for_unit("agent@sleeper.service")
    machine.succeed("agentctl matrix logs -n 5")

    # agents survive a reboot without any declaration
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("agentfleet-agents.service")
    machine.wait_for_unit("agent@sleeper.service")
    machine.fail("systemctl is-active agent@demo.service")
  '';
}
