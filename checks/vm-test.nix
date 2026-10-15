# NixOS VM test. Uses an inline test harness so Hermes is not built.
# Run with: nix build .#checks.x86_64-linux.vm   (needs KVM)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "agentfleet";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.core ];

      services.agentfleet = {
        flakeDir = "/root/flake";
        rebuildCommand = "echo would-run nixos-rebuild {action}";
        registry.dir = ./vm-registry;
        registry.hostPath = "/root/flake/agents";

        harnesses.custom = {
          description = "test harness";
          exec = ag: ag.settings.exec or null;
          init = ag: ag.settings.init or "";
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
  '';
}
