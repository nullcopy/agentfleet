# Custom harness — bring your own command. Everything comes from `settings`:
#
#   [settings]
#   exec = "/path/or/name/of/command --flags"   # omit for an on-demand agent
#   init = "echo first boot"                      # optional one-time script
#
# plus `packages = [ "python3" "nodejs" ]` for whatever the command needs.
{ lib, ... }:

{
  services.agents.harnesses.custom = {
    description = "Any command; configure via settings.exec / settings.init";
    exec = ag: ag.settings.exec or null;
    init = ag: ag.settings.init or "";
  };
}
