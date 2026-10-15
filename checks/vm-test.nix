# NixOS VM test. Uses an inline test harness so Hermes is not built, and the
# built-in Matrix server with a local operator account.
# Run with: nix build .#checks.x86_64-linux.vm   (needs KVM)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "agentfleet";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.core ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      services.agentfleet = {
        flakeDir = "/root/flake";
        rebuildCommand = "echo would-run nixos-rebuild {action}";
        registry.dir = ./vm-registry;
        registry.hostPath = "/root/flake/agents";

        matrix = {
          enable = true;
          serverName = "localhost";
          publicBaseUrl = "http://localhost:8008";
          operator = "@op:localhost";
        };

        harnesses.custom = {
          description = "test harness";
          exec = ag: ag.settings.exec or null;
          init = ag: ag.settings.init or "";
          supportsMatrix = true;
        };

        agents.sleeper = {
          harness = "custom";
          settings.exec = "${pkgs.coreutils}/bin/sleep infinity";
          settings.init = "echo init-ran > \"$HOME/init-marker\"";
          environment.GREETING = "hello";
        };

        agents.tool = {
          harness = "custom";
          description = "on-demand";
          packages = [ pkgs.util-linux ];
          matrix.enable = false;
        };
      };
    };

  testScript = ''
    import json
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # users, homes, perms
    machine.succeed("id agent-sleeper && id agent-tool && id agent-fromtoml")
    assert machine.succeed("stat -c %U:%a /srv/agents/sleeper").strip() == "agent-sleeper:750"
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/secrets.env").strip() == "root:400"

    # services
    machine.wait_for_unit("agent-sleeper.service")
    machine.succeed("test -f /srv/agents/sleeper/init-marker")
    machine.succeed("test -f /srv/agents/sleeper/.agentfleet/initialized")
    machine.fail("systemctl cat agent-tool.service")  # on-demand: no main unit
    machine.succeed("systemctl cat agent-tool-init.service")

    # TOML registry agent
    machine.wait_for_unit("agent-fromtoml.service")

    # state.json
    state = json.loads(machine.succeed("cat /etc/agents/state.json"))
    assert set(state["agents"]) == {"sleeper", "tool", "fromtoml"}, state["agents"].keys()
    assert state["agents"]["tool"]["service"] is None
    assert state["agents"]["fromtoml"]["source"] == "toml"
    assert state["agents"]["sleeper"]["env"]["GREETING"] == "hello"

    # agentctl: list / run / secrets / add / rm
    out = machine.succeed("agentctl list")
    assert "sleeper" in out and "active" in out and "on-demand" in out
    assert machine.succeed("agentctl run tool -- id -un").strip() == "agent-tool"
    assert machine.succeed("agentctl run tool -- sh -c 'echo $AGENT_NAME:$HOME'").strip() == "tool:/srv/agents/tool"
    machine.succeed("agentctl secrets set tool FOO='p@$s\"w' BAR=plain")
    assert machine.succeed("agentctl secrets list tool").split() == ["BAR", "FOO"]
    assert machine.succeed("agentctl run tool -- sh -c 'echo \"$FOO\"'").strip() == 'p@$s"w'
    # on-demand commands run inside the same sandbox as the units
    machine.fail("agentctl run tool -- touch /usr/agentfleet-escaped")
    machine.succeed("agentctl run tool -- touch /srv/agents/tool/ok")
    machine.fail("agentctl run tool -- unshare -U true")  # RestrictNamespaces
    assert ".bash_profile ->" in machine.succeed("ls -l /srv/agents/tool/.bash_profile")  # managed = symlink

    machine.succeed("mkdir -p /root/flake/agents && git -C /root/flake init -q")
    out = machine.succeed("agentctl add demo --harness custom --no-prompt --set exec=/bin/true --env A=1 --memory-max 1G")
    assert "would-run nixos-rebuild switch" in out
    toml = machine.succeed("cat /root/flake/agents/demo.toml")
    assert 'harness = "custom"' in toml and "[settings]" in toml and 'exec = "/bin/true"' in toml
    machine.succeed("git -C /root/flake ls-files --error-unmatch agents/demo.toml")

    out = machine.succeed("agentctl rm demo --yes")
    assert "would-run nixos-rebuild switch" in out
    machine.fail("test -e /root/flake/agents/demo.toml")
    machine.fail("agentctl rm sleeper --yes")  # defined in Nix, not removable

    # ---- Matrix server ----
    machine.wait_for_unit("matrix-synapse.service")
    machine.wait_for_unit("agentfleet-matrix.service")
    assert machine.succeed("stat -c %U:%a /var/lib/agents/sleeper/matrix.env").strip() == "root:400"
    machine.fail("test -e /var/lib/agents/tool/matrix.env")
    assert state["agents"]["sleeper"]["matrix"]["userId"] == "@sleeper:localhost"
    assert machine.succeed("agentctl run sleeper -- sh -c 'echo $MATRIX_USER_ID:$MATRIX_ALLOWED_USERS'").strip() == "@sleeper:localhost:@op:localhost"
    machine.succeed("agentctl run sleeper -- sh -c 'test -n \"$MATRIX_ACCESS_TOKEN\" && test \"$MATRIX_DEVICE_ID\" = AGENTFLEET'")
    out = machine.succeed("agentctl matrix status")
    assert "@sleeper:localhost" in out and "active" in out, out
    assert "@sleeper:localhost" in machine.succeed("agentctl list")

    # the agent's token works against the homeserver
    tok = machine.succeed("awk -F'\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    who = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {tok}' http://127.0.0.1:8008/_matrix/client/v3/account/whoami"))
    assert who["user_id"] == "@sleeper:localhost" and who["device_id"] == "AGENTFLEET", who

    # the operator did not exist at boot, so the introduction is retried on demand
    op = json.loads(machine.succeed("agentctl matrix register-user op"))
    machine.succeed("agentctl matrix introduce sleeper")
    sync = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op['access_token']}' 'http://127.0.0.1:8008/_matrix/client/v3/sync?timeout=0'"))
    invites = sync.get("rooms", {}).get("invite", {})
    assert len(invites) == 1, invites
    room = next(iter(invites))
    machine.succeed(f"curl -sf -X POST -H 'Authorization: Bearer {op['access_token']}' -d '{{}}' http://127.0.0.1:8008/_matrix/client/v3/join/{room}")
    msgs = json.loads(machine.succeed(f"curl -sf -H 'Authorization: Bearer {op['access_token']}' 'http://127.0.0.1:8008/_matrix/client/v3/rooms/{room}/messages?dir=b&limit=10'"))
    bodies = [e["content"].get("body", "") for e in msgs["chunk"] if e["type"] == "m.room.message"]
    assert any("I'm sleeper" in b for b in bodies), bodies

    # reconcile is idempotent: same token, no restart
    machine.succeed("systemctl restart agentfleet-matrix.service")
    assert tok == machine.succeed("awk -F'\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    machine.succeed("agentctl matrix rotate-token sleeper")
    assert tok != machine.succeed("awk -F'\"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/sleeper/matrix.env").strip()
    machine.fail(f"curl -sf -H 'Authorization: Bearer {tok}' http://127.0.0.1:8008/_matrix/client/v3/account/whoami")
    machine.fail("agentctl matrix deactivate sleeper")  # still declared
  '';
}
