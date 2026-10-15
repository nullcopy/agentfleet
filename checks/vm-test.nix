# NixOS VM test. Uses only the `custom` harness so nothing heavy is built.
# Run with: nix build .#checks.x86_64-linux.vm   (needs KVM)
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "agentfleet";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.core ];
      networking.nftables.enable = true;
      networking.firewall.enable = true;

      services.agents = {
        flakeDir = "/root/flake";
        rebuildCommand = "echo would-run nixos-rebuild {action}";
        registry.dir = ./vm-registry;
        registry.hostPath = "/root/flake/agents";

        agents.sleeper = {
          harness = "custom";
          settings.exec = "${pkgs.coreutils}/bin/sleep infinity";
          settings.init = "echo init-ran > \"$HOME/init-marker\"";
          egress = "none";
          environment.GREETING = "hello";
        };

        agents.tool = {
          harness = "custom";
          description = "on-demand";
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

    # egress rules landed in nftables
    rules = machine.succeed("nft list table inet agentfleet-egress")
    assert 'skuid "agent-sleeper"' in rules and "drop" in rules

    # agentctl: list / run / secrets / add / rm
    out = machine.succeed("agentctl list")
    assert "sleeper" in out and "active" in out and "on-demand" in out
    assert machine.succeed("agentctl run tool -- id -un").strip() == "agent-tool"
    assert machine.succeed("agentctl run tool -- sh -c 'echo $AGENT_NAME:$HOME'").strip() == "tool:/srv/agents/tool"
    machine.succeed("agentctl secrets set tool FOO=bar")
    assert machine.succeed("agentctl secrets list tool").strip() == "FOO"
    assert machine.succeed("agentctl run tool -- sh -c 'echo $FOO'").strip() == "bar"

    machine.succeed("mkdir -p /root/flake/agents && git -C /root/flake init -q")
    out = machine.succeed("agentctl add demo --harness custom --no-prompt --set exec=/bin/true --env A=1 --memory-max 1G")
    assert "would-run nixos-rebuild switch" in out
    toml = machine.succeed("cat /root/flake/agents/demo.toml")
    assert 'harness = "custom"' in toml and "[settings]" in toml and 'exec = "/bin/true"' in toml
    machine.succeed("git -C /root/flake ls-files --error-unmatch agents/demo.toml")

    machine.fail("agentctl rm sleeper --yes")  # defined in Nix, not removable
  '';
}
