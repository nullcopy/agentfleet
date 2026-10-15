#!/usr/bin/env python3
"""agentctl - manage declarative AI agents on this host (agentfleet).

The NixOS module renders everything this tool needs to /etc/agents/state.json.
agentctl itself knows nothing about Nix: it writes one TOML file per agent into
the registry directory, runs the host's rebuild command, and shells out to
systemd for the rest.
"""

import argparse
import json
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

STATE_PATH = os.environ.get("AGENTCTL_STATE", "/etc/agents/state.json")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
def die(msg, code=1):
    print(f"agentctl: {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg):
    print(f"agentctl: {msg}", file=sys.stderr)


def need_root():
    if os.geteuid() != 0:
        die("this command must run as root (try sudo)")


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        die(f"{STATE_PATH} not found; is services.agents enabled on this host?")
    except json.JSONDecodeError as e:
        die(f"{STATE_PATH} is not valid JSON: {e}")


def get_agent(state, name):
    a = state["agents"].get(name)
    if a is None:
        die(f"no agent named '{name}' (see `agentctl list`)")
    return a


def run(cmd, check=True, capture=False, **kw):
    return subprocess.run(
        cmd, check=check, text=True, capture_output=capture, **kw
    )


def systemctl(*args, check=True, capture=False):
    return run(["systemctl", *args], check=check, capture=capture)


def is_active(unit):
    if not unit:
        return False
    r = systemctl("is-active", unit, check=False, capture=True)
    return r.stdout.strip() == "active"


def unit_state(unit):
    r = systemctl("is-active", unit, check=False, capture=True)
    return r.stdout.strip() or "unknown"


def in_git(path):
    r = run(
        ["git", "-C", path, "rev-parse", "--is-inside-work-tree"],
        check=False,
        capture=True,
    )
    return r.returncode == 0 and r.stdout.strip() == "true"


def git_tracked(repo, path):
    r = run(
        ["git", "-C", repo, "ls-files", "--error-unmatch", path],
        check=False,
        capture=True,
    )
    return r.returncode == 0


def confirm(prompt):
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


# ----------------------------------------------------------------------------
# secrets file (KEY=VALUE, root-owned 0400)
# ----------------------------------------------------------------------------
def read_env_file(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k.strip()] = v
    except FileNotFoundError:
        pass
    return out


def write_env_file(path, values):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".secrets.")
    with os.fdopen(fd, "w") as f:
        f.write("# Managed by agentctl. KEY=VALUE, one per line.\n")
        for k, v in sorted(values.items()):
            f.write(f"{k}={shlex.quote(v) if any(c in v for c in ' #\"\\$') else v}\n")
    os.chmod(tmp, 0o400)
    os.chown(tmp, 0, 0)
    os.replace(tmp, path)


def parse_kv(items, what):
    out = {}
    for item in items or []:
        if "=" not in item:
            die(f"{what} must be KEY=VALUE, got '{item}'")
        k, v = item.split("=", 1)
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            die(f"invalid {what} name '{k}'")
        out[k] = v
    return out


def prompt_secrets(harness_def, provided, no_prompt):
    """Return the secrets to write for a new agent."""
    values = dict(provided)
    for s in harness_def.get("secrets", []):
        name = s["name"]
        if name in values:
            continue
        if no_prompt or not sys.stdin.isatty():
            if s.get("required"):
                die(f"secret {name} is required by this harness; pass --secret {name}=...")
            continue
        label = f"{name}" + (f" ({s['description']})" if s.get("description") else "")
        suffix = " [required]" if s.get("required") else " [enter to skip]"
        import getpass

        while True:
            v = getpass.getpass(f"  {label}{suffix}: ")
            if v or not s.get("required"):
                break
            print("  this secret is required")
        if v:
            values[name] = v
    return values


# ----------------------------------------------------------------------------
# TOML emission (stdlib only; we never rewrite a file we did not create)
# ----------------------------------------------------------------------------
def toml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_scalar(x) for x in v) + "]"
    die(f"cannot encode {v!r} as TOML")


def toml_tables(d, prefix, out):
    scalars = {k: v for k, v in d.items() if not isinstance(v, dict)}
    tables = {k: v for k, v in d.items() if isinstance(v, dict)}
    if scalars or not tables:
        if prefix:
            out.append(f"\n[{prefix}]")
        for k, v in scalars.items():
            key = k if re.match(r"^[A-Za-z0-9_-]+$", k) else json.dumps(k)
            out.append(f"{key} = {toml_scalar(v)}")
    for k, v in tables.items():
        toml_tables(v, f"{prefix}.{k}" if prefix else k, out)


def coerce(v):
    if v in ("true", "false"):
        return v == "true"
    if re.match(r"^-?\d+$", v):
        return int(v)
    return v


def set_nested(d, dotted, value):
    parts = dotted.split(".")
    for p in parts[:-1]:
        d = d.setdefault(p, {})
        if not isinstance(d, dict):
            die(f"--set {dotted}: '{p}' is not a table")
    d[parts[-1]] = value


def render_agent_toml(args):
    top = {"harness": args.harness}
    if args.description:
        top["description"] = args.description
    if args.model:
        top["model"] = args.model
    top["autostart"] = not args.no_autostart
    if args.memory_max:
        top["memory_max"] = args.memory_max
    if args.cpu_quota:
        top["cpu_quota"] = args.cpu_quota
    if args.package:
        top["packages"] = args.package
    out = [f"# agent '{args.name}' - created by agentctl; edit freely, then `agentctl apply`."]
    toml_tables(top, "", out)
    env = parse_kv(args.env, "--env")
    if env:
        toml_tables(env, "environment", out)
    settings = {}
    for item in args.set or []:
        if "=" not in item:
            die(f"--set expects key=value, got '{item}'")
        k, v = item.split("=", 1)
        set_nested(settings, k, coerce(v))
    if settings:
        toml_tables(settings, "settings", out)
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------
# apply
# ----------------------------------------------------------------------------
def apply(state, dry_run=False):
    action = "dry-activate" if dry_run else "switch"
    cmd = state["rebuildCommand"].replace("{action}", action)
    print(f"==> {cmd}")
    r = subprocess.run(cmd, shell=True)
    if r.returncode != 0:
        die(f"rebuild failed (exit {r.returncode}); the registry change is still on disk", r.returncode)


# ----------------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------------
def cmd_list(state, args):
    rows = []
    for name in sorted(state["agents"]):
        a = state["agents"][name]
        if not a.get("enabled", True):
            st = "disabled"
        elif a.get("service"):
            st = unit_state(a["service"])
        else:
            st = "on-demand"
        rows.append((name, a["harness"], a.get("source", "nix"), st, a.get("user", ""), a.get("description", "")))
    if not rows:
        print("no agents defined")
        return
    hdr = ("NAME", "HARNESS", "SOURCE", "STATE", "USER", "DESCRIPTION")
    widths = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(5)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths) + "  {}"
    print(fmt.format(*hdr))
    for r in rows:
        print(fmt.format(*r))


def cmd_harnesses(state, args):
    for name in sorted(state["harnesses"]):
        h = state["harnesses"][name]
        print(f"{name}: {h.get('description', '')}")
        for s in h.get("secrets", []):
            flag = "required" if s.get("required") else "optional"
            print(f"    {s['name']:<28} {flag:<9} {s.get('description', '')}")


def cmd_add(state, args):
    need_root()
    name = args.name
    if not NAME_RE.match(name):
        die(f"name '{name}' must match {NAME_RE.pattern}")
    if name in state["agents"]:
        die(f"agent '{name}' already exists")
    if args.harness not in state["harnesses"]:
        die(f"unknown harness '{args.harness}' (see `agentctl harnesses`)")
    if not state["registry"]["enabled"]:
        die("this host has no TOML registry (services.agents.registry.dir is unset); define agents in Nix instead")
    try:
        pwd.getpwnam(f"{state['userPrefix']}{name}")
        die(f"user {state['userPrefix']}{name} already exists on this host")
    except KeyError:
        pass

    reg = state["registry"]["hostPath"]
    path = os.path.join(reg, f"{name}.toml")
    if os.path.exists(path):
        die(f"{path} already exists (run `agentctl apply` to deploy it)")

    secrets = prompt_secrets(
        state["harnesses"][args.harness], parse_kv(args.secret, "--secret"), args.no_prompt
    )

    os.makedirs(reg, exist_ok=True)
    with open(path, "w") as f:
        f.write(render_agent_toml(args))
    print(f"wrote {path}")

    flake = state["flakeDir"]
    if in_git(flake):
        # Flakes only see tracked files; an untracked registry entry is invisible.
        run(["git", "-C", flake, "add", path])
        print("git: staged (commit when you are happy with it)")

    if secrets:
        secrets_path = os.path.join(state["stateDir"], name, "secrets.env")
        write_env_file(secrets_path, secrets)
        print(f"wrote {len(secrets)} secret(s) to {secrets_path}")

    if args.no_apply:
        print("skipping rebuild (--no-apply); run `agentctl apply` when ready")
        return
    apply(state)
    print(f"agent '{name}' is up. Next: agentctl status {name} | agentctl shell {name}")


def cmd_rm(state, args):
    need_root()
    path = os.path.join(state["registry"]["hostPath"], f"{args.name}.toml")
    a = state["agents"].get(args.name)
    if a is None:
        if not os.path.exists(path):
            die(f"no agent named '{args.name}' (see `agentctl list`)")
        # Registered with --no-apply (or applied elsewhere) but not deployed here yet.
        a = {
            "source": "toml",
            "home": os.path.join(state["homeBase"], args.name),
            "stateDir": os.path.join(state["stateDir"], args.name),
        }
    if a.get("source") != "toml":
        die(f"agent '{args.name}' is defined in Nix, not the registry; remove it from your configuration instead")
    if not args.yes:
        what = "and PURGE its home, state and secrets" if args.purge else "(home and state are kept)"
        if not confirm(f"Remove agent '{args.name}' {what}?"):
            die("aborted", 2)

    for unit in (a.get("service"), a.get("initService")):
        if unit and is_active(unit):
            systemctl("stop", unit, check=False)

    flake = state["flakeDir"]
    if os.path.exists(path):
        if in_git(flake) and git_tracked(flake, path):
            run(["git", "-C", flake, "rm", "-q", "-f", path])
        else:
            os.remove(path)
        print(f"removed {path}")
    else:
        warn(f"{path} was already gone")

    if not args.no_apply:
        apply(state)

    if args.purge:
        for p in (a.get("home"), a.get("stateDir")):
            if p and os.path.isdir(p):
                shutil.rmtree(p)
                print(f"purged {p}")
    print(f"agent '{args.name}' removed")


def cmd_apply(state, args):
    need_root()
    apply(state, dry_run=args.dry_run)


def service_or_die(a, name):
    unit = a.get("service")
    if not unit:
        die(f"agent '{name}' uses an on-demand harness ({a['harness']}); there is no service. Use `agentctl run {name} -- <cmd>`")
    return unit


def cmd_lifecycle(state, args):
    need_root()
    a = get_agent(state, args.name)
    systemctl(args.command, service_or_die(a, args.name))


def cmd_status(state, args):
    if not args.name:
        return cmd_list(state, args)
    a = get_agent(state, args.name)
    units = [u for u in (a.get("service"), a.get("initService")) if u]
    if not units:
        print(f"{args.name}: on-demand harness, no units")
        return
    systemctl("status", "--no-pager", "--lines=0", *units, check=False)


def cmd_logs(state, args):
    a = get_agent(state, args.name)
    units = [u for u in (a.get("service"), a.get("initService")) if u]
    if not units:
        die(f"agent '{args.name}' has no service; nothing is logged under a unit")
    cmd = ["journalctl", "--no-pager" if not args.follow else "-f", "-n", str(args.lines)]
    for u in units:
        cmd += ["-u", u]
    os.execvp("journalctl", cmd)


def agent_environ(state, a):
    env = {
        "HOME": a["home"],
        "USER": a["user"],
        "LOGNAME": a["user"],
        "SHELL": a.get("shell", "/bin/sh"),
        "TERM": os.environ.get("TERM", "xterm-256color"),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "PATH": f"{a['path']}:/run/wrappers/bin:/run/current-system/sw/bin",
    }
    env.update(a.get("env", {}))
    env.update(read_env_file(a["secretsFile"]))
    return env


def exec_as_agent(state, a, argv):
    need_root()
    if not a.get("enabled", True):
        die("agent is disabled")
    env = agent_environ(state, a)
    os.chdir(a["home"])
    cmd = ["runuser", "-u", a["user"], "--", "env", "-i"]
    cmd += [f"{k}={v}" for k, v in env.items()]
    cmd += argv
    os.execvp("runuser", cmd)


def cmd_shell(state, args):
    a = get_agent(state, args.name)
    exec_as_agent(state, a, [a.get("shell", "/bin/sh"), "--login"])


def cmd_run(state, args):
    a = get_agent(state, args.name)
    if not args.cmd:
        die("usage: agentctl run <name> -- <command...>")
    exec_as_agent(state, a, args.cmd)


def cmd_secrets(state, args):
    need_root()
    a = get_agent(state, args.name)
    path = a["secretsFile"]
    if args.sub == "list":
        keys = sorted(read_env_file(path))
        print("\n".join(keys) if keys else f"(no secrets in {path})")
        return
    if args.sub == "set":
        values = read_env_file(path)
        values.update(parse_kv(args.pairs, "secret"))
        write_env_file(path, values)
        print(f"updated {path}")
    elif args.sub == "edit":
        editor = os.environ.get("EDITOR") or os.environ.get("VISUAL") or "vi"
        fd, tmp = tempfile.mkstemp(prefix="agentctl-secrets.", suffix=".env")
        os.close(fd)
        try:
            if os.path.exists(path):
                shutil.copyfile(path, tmp)
            os.chmod(tmp, 0o600)
            subprocess.run([*shlex.split(editor), tmp], check=True)
            write_env_file(path, read_env_file(tmp))
            print(f"updated {path}")
        finally:
            os.remove(tmp)
    unit = a.get("service")
    if unit and is_active(unit):
        systemctl("restart", unit)
        print(f"restarted {unit}")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(
        prog="agentctl",
        description="Manage declarative AI agents on this host. Each agent is its own Unix user.",
        epilog="State comes from %s (override with $AGENTCTL_STATE)." % STATE_PATH,
    )
    sub = p.add_subparsers(dest="command", metavar="<command>")
    sub.required = True

    s = sub.add_parser("list", help="show all agents and their service state")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("harnesses", help="list available harness recipes and their secrets")
    s.set_defaults(func=cmd_harnesses)

    s = sub.add_parser("add", help="register a new agent and apply", description="Register a new agent: write <registry>/<name>.toml, store its secrets, rebuild.")
    s.add_argument("name")
    s.add_argument("--harness", required=True, help="recipe name (see `agentctl harnesses`)")
    s.add_argument("--model", help="default model id for the harness")
    s.add_argument("--description", help="free text shown in `agentctl list`")
    s.add_argument("--no-autostart", action="store_true", help="do not start the service at boot")
    s.add_argument("--memory-max", metavar="SIZE", help="systemd MemoryMax, e.g. 4G")
    s.add_argument("--cpu-quota", metavar="PCT", help="systemd CPUQuota, e.g. 200%%")
    s.add_argument("--package", action="append", metavar="PKG", help="extra nixpkgs package on PATH (repeatable)")
    s.add_argument("--env", action="append", metavar="K=V", help="non-secret environment variable (repeatable)")
    s.add_argument("--set", action="append", metavar="KEY=VAL", help="harness setting, dotted keys allowed, e.g. gateway.port=18790 (repeatable)")
    s.add_argument("--secret", action="append", metavar="K=V", help="set a secret now instead of being prompted (repeatable)")
    s.add_argument("--no-prompt", action="store_true", help="never prompt for secrets")
    s.add_argument("--no-apply", action="store_true", help="write the registry entry but do not rebuild")
    s.set_defaults(func=cmd_add)

    s = sub.add_parser("rm", help="unregister an agent and apply")
    s.add_argument("name")
    s.add_argument("--purge", action="store_true", help="also delete the home directory, state and secrets")
    s.add_argument("--yes", "-y", action="store_true", help="skip confirmation")
    s.add_argument("--no-apply", action="store_true", help="remove the registry entry but do not rebuild")
    s.set_defaults(func=cmd_rm)

    s = sub.add_parser("apply", help="rebuild the host from the current registry")
    s.add_argument("--dry-run", action="store_true", help="show what would change without switching")
    s.set_defaults(func=cmd_apply)

    for name, help_ in (("start", "start the agent's service"), ("stop", "stop the agent's service"), ("restart", "restart the agent's service")):
        s = sub.add_parser(name, help=help_)
        s.add_argument("name")
        s.set_defaults(func=cmd_lifecycle)

    s = sub.add_parser("status", help="service status for one agent, or a table for all")
    s.add_argument("name", nargs="?")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("logs", help="show the agent's journal")
    s.add_argument("name")
    s.add_argument("-f", "--follow", action="store_true")
    s.add_argument("-n", "--lines", type=int, default=100)
    s.set_defaults(func=cmd_logs)

    s = sub.add_parser("shell", help="open a login shell as the agent's user, with its secrets loaded")
    s.add_argument("name")
    s.set_defaults(func=cmd_shell)

    s = sub.add_parser("run", help="run one command as the agent's user: agentctl run <name> -- <cmd...>")
    s.add_argument("name")
    s.add_argument("cmd", nargs=argparse.REMAINDER)
    s.set_defaults(func=cmd_run)

    s = sub.add_parser("secrets", help="manage the agent's secrets file")
    ss = s.add_subparsers(dest="sub", metavar="<set|edit|list>")
    ss.required = True
    x = ss.add_parser("set", help="create or update KEY=VALUE pairs; restarts a running service")
    x.add_argument("name")
    x.add_argument("pairs", nargs="+", metavar="KEY=VALUE")
    x = ss.add_parser("edit", help="open the secrets file in $EDITOR")
    x.add_argument("name")
    x = ss.add_parser("list", help="print secret names, never values")
    x.add_argument("name")
    s.set_defaults(func=cmd_secrets)
    return p


def main():
    args = build_parser().parse_args()
    if args.command == "run" and args.cmd and args.cmd[0] == "--":
        args.cmd = args.cmd[1:]
    state = load_state()
    args.func(state, args)


if __name__ == "__main__":
    main()
