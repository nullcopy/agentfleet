#!/usr/bin/env python3
"""agentctl - manage the Hermes agents on this host (agentfleet).

The NixOS module renders everything this tool needs to /etc/agents/state.json.
agentctl itself knows nothing about Nix: it writes one TOML file per agent into
the registry directory, runs nixos-rebuild, and shells out to systemd and to
agentfleet-matrix for the rest.
"""

import argparse
import getpass
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
DEFAULT_NAME_REGEX = "[a-z][a-z0-9-]{0,30}"


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
        die(f"{STATE_PATH} not found; is services.agentfleet enabled on this host?")
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
    r = run(["systemctl", *args], check=False, capture=capture)
    if check and r.returncode != 0:
        die(f"`systemctl {' '.join(args)}` failed (exit {r.returncode}); see `agentctl status` and `agentctl matrix status`", r.returncode)
    return r


def is_active(unit):
    if not unit:
        return False
    r = systemctl("is-active", unit, check=False, capture=True)
    return r.stdout.strip() == "active"


def unit_state(unit):
    r = systemctl("is-active", unit, check=False, capture=True)
    return r.stdout.strip() or "unknown"


def git(repo, *args, check=True, capture=False):
    # The flake checkout is usually owned by the admin, not root; without
    # safe.directory git refuses to touch it ("dubious ownership").
    cmd = ["git", "-c", f"safe.directory={repo}", "-C", repo, *args]
    r = run(cmd, check=False, capture=capture)
    if check and r.returncode != 0:
        detail = (r.stderr or "").strip() if capture else ""
        die(f"`{' '.join(cmd)}` failed" + (f": {detail}" if detail else ""))
    return r


def in_git(path):
    r = git(path, "rev-parse", "--is-inside-work-tree", check=False, capture=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def git_tracked(repo, path):
    return git(repo, "ls-files", "--error-unmatch", path, check=False, capture=True).returncode == 0


def confirm(prompt):
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


def valid_name(state, name):
    pattern = state.get("nameRegex", DEFAULT_NAME_REGEX)
    if not re.fullmatch(pattern, name):
        die(f"name '{name}' must match {pattern}")
    user = f"{state['userPrefix']}{name}"
    limit = state.get("maxUserLength", 32)
    if len(user) > limit:
        die(f"user name '{user}' would be longer than {limit} characters; pick a shorter name")


# ----------------------------------------------------------------------------
# secrets file (KEY="VALUE", root-owned 0400; the systemd EnvironmentFile dialect)
# ----------------------------------------------------------------------------
_ENV_ESCAPE = '\\"$`'


def read_env_file(path):
    """Parse KEY=VALUE lines. Values may be bare, 'single' or "double" quoted;
    inside double quotes a backslash escapes \\ " $ and ` and a quoted value
    may span lines, exactly as systemd reads them."""
    out = {}
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return out
    i, n = 0, len(text)
    while i < n:
        eol = text.find("\n", i)
        if eol < 0:
            eol = n
        line = text[i:eol]
        i = eol + 1
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, rest = stripped.split("=", 1)
        key, rest = key.strip(), rest.lstrip()
        if rest[:1] == '"':
            val, j = [], 1
            while True:
                if j >= len(rest):  # quoted value continues on the next line
                    if i >= n:
                        break
                    eol = text.find("\n", i)
                    if eol < 0:
                        eol = n
                    rest, j = "\n" + text[i:eol], 0
                    i = eol + 1
                    continue
                c = rest[j]
                if c == "\\" and j + 1 < len(rest) and rest[j + 1] in _ENV_ESCAPE:
                    val.append(rest[j + 1])
                    j += 2
                elif c == '"':
                    break
                else:
                    val.append(c)
                    j += 1
            out[key] = "".join(val)
        elif rest[:1] == "'":
            end = rest.find("'", 1)
            out[key] = rest[1:end] if end > 0 else rest[1:]
        else:
            out[key] = rest.rstrip()
    return out


def env_quote(v):
    return '"' + "".join("\\" + c if c in _ENV_ESCAPE else c for c in v) + '"'


def write_env_file(path, values):
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".secrets.")
        with os.fdopen(fd, "w") as f:
            f.write('# Managed by agentctl. KEY="VALUE", one per line.\n')
            for k, v in sorted(values.items()):
                f.write(f"{k}={env_quote(v)}\n")
        os.chmod(tmp, 0o400)
        os.chown(tmp, 0, 0)
        os.replace(tmp, path)
    except OSError as e:
        die(f"cannot write {path}: {e.strerror}. If this file comes from sops-nix/agenix, change it there instead")


def parse_kv(items, what, prompt=False):
    """KEY=VALUE pairs; with prompt=True a bare KEY asks for the value with
    hidden input, so secrets never have to pass through the shell history."""
    out = {}
    for item in items or []:
        if "=" in item:
            k, v = item.split("=", 1)
        elif prompt:
            k, v = item, None
        else:
            die(f"{what} must be KEY=VALUE, got '{item}'")
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            die(f"invalid {what} name '{k}'")
        if v is None:
            if not sys.stdin.isatty():
                die(f"{what} {k}: no value given and stdin is not a terminal")
            v = getpass.getpass(f"  {k}: ")
            if not v:
                die(f"{what} {k}: empty value")
        out[k] = v
    return out


def prompt_secrets(state, provided, no_prompt):
    """Return the secrets to write for a new agent: one provider key is enough."""
    values = dict(provided)
    for s in state.get("secrets", []):
        name = s["name"]
        if name in values or no_prompt or not sys.stdin.isatty():
            continue
        label = f"{name}" + (f" ({s['description']})" if s.get("description") else "")
        v = getpass.getpass(f"  {label} [enter to skip]: ")
        if v:
            values[name] = v
    if not values:
        warn("no model provider key given; the agent will start but cannot answer until you run `agentctl secrets set`")
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
    """Turn a --set value into a TOML literal when it round-trips exactly
    (so "0123" and "1_000" stay strings); use --set-str to force a string."""
    if v in ("true", "false"):
        return v == "true"
    try:
        if str(int(v)) == v:
            return int(v)
    except ValueError:
        pass
    return v


def set_nested(d, dotted, value):
    parts = dotted.split(".")
    for p in parts[:-1]:
        d = d.setdefault(p, {})
        if not isinstance(d, dict):
            die(f"--set {dotted}: '{p}' is not a table")
    d[parts[-1]] = value


_SECRET_LIKE = re.compile(r".*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL).*")


def secret_like(key):
    """Mirrors the module's check: the registry is world-readable (Nix store)
    and committed, so credential-looking names are refused there."""
    u = key.upper()
    return bool(_SECRET_LIKE.match(u)) and not u.endswith("_ENV")


def refuse_secrets(name, keys):
    bad = [k for k in keys if secret_like(k.rsplit(".", 1)[-1])]
    if bad:
        hint = (
            f"use --secret {bad[0]} (or `agentctl secrets set {name} {bad[0]}`)"
            if "." not in bad[0]
            else f"store the value with --secret <NAME> and point Hermes at it with --set {bad[0]}_env=<NAME>"
        )
        die(
            f"{', '.join(bad)} look(s) like a secret and would land in the registry, which is copied "
            f"into the world-readable Nix store and committed to git; {hint} instead"
        )


def render_agent_toml(args):
    top = {}
    if args.description:
        top["description"] = args.description
    if args.model:
        top["model"] = args.model
    if args.memory_max:
        top["memory_max"] = args.memory_max
    if args.cpu_quota:
        top["cpu_quota"] = args.cpu_quota
    if args.package:
        top["packages"] = args.package
    out = [f"# agent '{args.name}' - created by agentctl; edit freely, then rebuild the host."]
    toml_tables(top, "", out)
    env = parse_kv(args.env, "--env")
    refuse_secrets(args.name, env)
    if env:
        toml_tables(env, "environment", out)
    settings = {}
    for item, literal in [(x, True) for x in args.set or []] + [(x, False) for x in args.set_str or []]:
        if "=" not in item:
            die(f"--set expects key=value, got '{item}'")
        k, v = item.split("=", 1)
        refuse_secrets(args.name, [k])
        set_nested(settings, k, coerce(v) if literal else v)
    if settings:
        toml_tables(settings, "settings", out)
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------
# rebuild (plain nixos-rebuild switch by default; agentctl adds nothing to it)
# ----------------------------------------------------------------------------
def rebuild_cmd(state):
    return state["rebuildCommand"].replace("{action}", "switch")


def rebuild(state):
    cmd = rebuild_cmd(state)
    print(f"==> {cmd}")
    r = subprocess.run(cmd, shell=True)
    if r.returncode != 0:
        die(f"rebuild failed (exit {r.returncode}); the registry change is still on disk", r.returncode)


def removed_agents(state):
    """Names that still have a home or state directory but are no longer
    defined: removed with `rm` but not purged. They match the name regex so
    stray directories are ignored."""
    pattern = state.get("nameRegex", DEFAULT_NAME_REGEX)
    found = set()
    for base in (state["homeBase"], state["stateDir"]):
        try:
            entries = os.listdir(base)
        except OSError:
            continue
        for n in entries:
            if re.fullmatch(pattern, n) and os.path.isdir(os.path.join(base, n)):
                found.add(n)
    return sorted(found - set(state["agents"]))


def enabled_services(state):
    return [a["service"] for _, a in sorted(state["agents"].items()) if a.get("service")]


# ----------------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------------
def cmd_names(state, args):
    """Used by shell completion."""
    names = removed_agents(state) if args.removed else sorted(state["agents"])
    print("\n".join(names))


def cmd_list(state, args):
    rows = []
    for name in sorted(state["agents"]):
        a = state["agents"][name]
        st = unit_state(a["service"]) if a.get("enabled", True) else "disabled"
        rows.append((name, st, a.get("userId", ""), a.get("model") or "", a.get("description", "")))
    for name in removed_agents(state):
        rows.append((name, "removed", "", "", f"leftover files; `agentctl purge {name}` deletes them"))
    if not rows:
        print("no agents defined")
        return
    hdr = ("NAME", "STATE", "MATRIX", "MODEL", "DESCRIPTION")
    widths = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(4)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths) + "  {}"
    print(fmt.format(*hdr))
    for r in rows:
        print(fmt.format(*r))


def cmd_add(state, args):
    need_root()
    name = args.name
    valid_name(state, name)
    if name in state["agents"]:
        die(f"agent '{name}' already exists")
    if not state["registry"]["enabled"]:
        die("this host has no TOML registry (services.agentfleet.registry.dir is unset); define agents in Nix instead")
    try:
        pwd.getpwnam(f"{state['userPrefix']}{name}")
        die(f"user {state['userPrefix']}{name} already exists on this host")
    except KeyError:
        pass

    reg = state["registry"]["hostPath"]
    path = os.path.join(reg, f"{name}.toml")
    if os.path.exists(path):
        die(f"{path} already exists (rebuild the host to deploy it: {rebuild_cmd(state)})")

    secrets = prompt_secrets(state, parse_kv(args.secret, "--secret", prompt=True), args.no_prompt)

    os.makedirs(reg, exist_ok=True)
    with open(path, "w") as f:
        f.write(render_agent_toml(args))
    print(f"wrote {path}")

    flake = state["flakeDir"]
    if in_git(flake):
        # Flakes only see tracked files; an untracked registry entry is invisible.
        git(flake, "add", path)
        print("git: staged (commit when you are happy with it)")

    if secrets:
        secrets_path = os.path.join(state["stateDir"], name, "secrets.env")
        write_env_file(secrets_path, secrets)
        print(f"wrote {len(secrets)} secret(s) to {secrets_path}")

    if args.no_rebuild:
        print(f"skipping rebuild (--no-rebuild); run `{rebuild_cmd(state)}` when ready")
        return
    rebuild(state)
    report_after_rebuild(state, name)


def report_after_rebuild(state, name):
    """The rebuild succeeded; say whether the agent actually runs. The new
    state.json is in place now, so read it afresh."""
    new = load_state()
    a = new["agents"].get(name)
    unit = (a or {}).get("service")
    if unit and is_active(unit):
        operator = new["matrix"]["operator"]
        rec = {}
        try:
            with open(os.path.join(new["matrix"]["stateDir"], "agents", f"{name}.json")) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            pass
        if rec.get("introduced_room"):
            print(f"agent '{name}' is up and has invited {operator} to {rec['introduced_room']}. Accept the invite in your Matrix client.")
        else:
            warn(f"agent '{name}' is up, but its invitation to {operator} could not be delivered.")
            warn("Run `agentctl matrix check` to see what is wrong with DNS, proxy or federation; the invite is retried on every rebuild and by `agentctl matrix introduce " + name + "`.")
        print(f"Next: agentctl logs {name} -f")
        return
    synapse = new["matrix"]["synapseService"]
    if not is_active(synapse):
        warn(f"agent '{name}' is NOT running: the Matrix server ({synapse}) is down and the agents depend on it.")
        warn(f"Inspect it with `agentctl matrix logs -n 50`; once it is up, run `agentctl start {name}`.")
    else:
        warn(f"agent '{name}' is NOT running ({unit_state(unit) if unit else 'no unit'}); see `agentctl logs {name}`.")
    sys.exit(1)


def cmd_rm(state, args):
    need_root()
    path = os.path.join(state["registry"]["hostPath"], f"{args.name}.toml")
    a = state["agents"].get(args.name)
    if a is None:
        if not os.path.exists(path):
            die(f"no agent named '{args.name}' (see `agentctl list`)")
        # Registered with --no-rebuild (or applied elsewhere) but not deployed here yet.
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
            git(flake, "rm", "-q", "-f", path)
        else:
            os.remove(path)
        print(f"removed {path}")
    else:
        warn(f"{path} was already gone")

    if not args.no_rebuild:
        rebuild(state)

    if args.purge:
        # The rebuild above locked the account; purge deactivates it for good.
        purge_leftovers(state, args.name, deactivate=not args.no_rebuild)
    elif os.path.isdir(a.get("home") or ""):
        warn(
            f"{a['home']} was kept. Its files still belong to the freed UID, which a "
            f"future agent may receive; `agentctl purge {args.name}` deletes them"
        )
    print(f"agent '{args.name}' removed")


def purge_leftovers(state, name, deactivate=True):
    for p in (os.path.join(state["homeBase"], name), os.path.join(state["stateDir"], name)):
        if os.path.isdir(p):
            shutil.rmtree(p)
            print(f"purged {p}")
    if deactivate:
        r = run([state["matrix"]["ctl"], "deactivate", name], check=False, capture=True)
        out = (r.stdout + r.stderr).strip()
        if r.returncode != 0 and "no Matrix record" in out:
            print(f"no Matrix account to deactivate for '{name}'")
        elif out:
            print(out)


def cmd_purge(state, args):
    need_root()
    valid_name(state, args.name)
    if args.name in state["agents"]:
        die(f"agent '{args.name}' is still defined; use `agentctl rm {args.name} --purge`")
    toml = os.path.join(state["registry"]["hostPath"], f"{args.name}.toml")
    if os.path.exists(toml):
        die(f"{toml} still exists; remove it with `agentctl rm {args.name} --purge`")
    if args.name not in removed_agents(state):
        print(f"nothing left on disk for '{args.name}'; deactivating its Matrix account if any")
    elif not args.yes and not confirm(f"Delete home, state and secrets of removed agent '{args.name}' and deactivate its Matrix account for good?"):
        die("aborted", 2)
    purge_leftovers(state, args.name)
    print(f"agent '{args.name}' purged")


def service_or_die(a, name):
    unit = a.get("service")
    if not unit:
        die(f"agent '{name}' is disabled; set enable = true in its registry file and rebuild")
    return unit


def cmd_lifecycle(state, args):
    need_root()
    if args.all:
        units = enabled_services(state)
        if not units:
            die("no enabled agents")
        systemctl(args.command, *units)
        print(f"{args.command}ed {len(units)} agent(s)" if args.command != "stop" else f"stopped {len(units)} agent(s)")
        return
    if not args.name:
        die(f"agentctl {args.command}: give an agent name or --all")
    a = get_agent(state, args.name)
    systemctl(args.command, service_or_die(a, args.name))


def cmd_status(state, args):
    if not args.name:
        return cmd_list(state, args)
    a = get_agent(state, args.name)
    units = [u for u in (a.get("service"), a.get("initService")) if u]
    if not units:
        print(f"{args.name}: disabled, no units")
        return
    systemctl("status", "--no-pager", "--lines=0", *units, check=False)


def cmd_logs(state, args):
    a = get_agent(state, args.name)
    units = [u for u in (a.get("service"), a.get("initService")) if u]
    if not units:
        die(f"agent '{args.name}' is disabled; nothing is logged under a unit")
    cmd = ["journalctl", "--no-pager" if not args.follow else "-f", "-n", str(args.lines)]
    for u in units:
        cmd += ["-u", u]
    os.execvp("journalctl", cmd)


def cmd_matrix(state, args):
    m = state["matrix"]
    synapse, reconcile = m["synapseService"], m["reconcileService"]
    sub = args.sub or "status"
    if sub != "check":
        need_root()
    if sub in ("status", "check", "introduce", "rotate-token", "deactivate"):
        ctl = m["ctl"]
        extra = [args.name] if getattr(args, "name", None) else []
        os.execvp(ctl, [ctl, sub, *extra])
    if sub == "stop":
        # Agents require the server; systemd stops them with it.
        systemctl("stop", synapse)
        print(f"stopped {synapse} and, with it, the reconciler and every agent")
    elif sub == "start":
        systemctl("start", synapse, reconcile, *enabled_services(state))
        print(f"started {synapse}, {reconcile} and every enabled agent")
    elif sub == "restart":
        # Restart propagates through Requires= to the reconciler and the agents.
        systemctl("restart", synapse)
        print(f"restarted {synapse}; the reconciler and the agents followed")
    elif sub == "logs":
        cmd = ["journalctl", "-f" if args.follow else "--no-pager", "-n", str(args.lines), "-u", synapse, "-u", reconcile]
        os.execvp("journalctl", cmd)


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
        values.update(parse_kv(args.pairs, "secret", prompt=True))
        write_env_file(path, values)
        print(f"updated {path}")
    elif args.sub == "edit":
        editor = os.environ.get("EDITOR") or os.environ.get("VISUAL") or "vi"
        try:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".edit.", suffix=".env")
        except OSError as e:
            die(f"cannot create a scratch file next to {path}: {e.strerror}")
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
        description="Manage the Hermes agents on this host. Each agent is its own Unix user with its own Matrix account.",
        epilog="State comes from %s (override with $AGENTCTL_STATE)." % STATE_PATH,
    )
    sub = p.add_subparsers(dest="command", metavar="<command>")
    sub.required = True

    s = sub.add_parser("list", help="show all agents, their state and Matrix id")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("names", help=argparse.SUPPRESS)
    s.add_argument("--removed", action="store_true")
    s.set_defaults(func=cmd_names)

    s = sub.add_parser("add", help="create an agent and rebuild", description="Create an agent: write <registry>/<name>.toml, store its provider key, rebuild the host. It then introduces itself to you on Matrix.")
    s.add_argument("name")
    s.add_argument("--model", help="Hermes model id, e.g. anthropic/claude-sonnet-5.5")
    s.add_argument("--description", help="free text shown in `agentctl list` and in the introduction")
    s.add_argument("--memory-max", metavar="SIZE", help="systemd MemoryMax, e.g. 4G")
    s.add_argument("--cpu-quota", metavar="PCT", help="systemd CPUQuota, e.g. 200%%")
    s.add_argument("--package", action="append", metavar="PKG", help="extra nixpkgs package on PATH (repeatable)")
    s.add_argument("--env", action="append", metavar="K=V", help="non-secret environment variable (repeatable)")
    s.add_argument("--set", action="append", metavar="KEY=VAL", help="Hermes config.yaml key, dotted keys allowed; integers and true/false become TOML literals (repeatable)")
    s.add_argument("--set-str", action="append", metavar="KEY=VAL", help="like --set but the value is always a string")
    s.add_argument("--secret", action="append", metavar="KEY[=VALUE]", help="a key to store; without =VALUE you are prompted for it, which keeps it out of the shell history (repeatable)")
    s.add_argument("--no-prompt", action="store_true", help="never prompt for secrets")
    s.add_argument("--no-rebuild", action="store_true", help="write the registry entry but do not rebuild the host")
    s.set_defaults(func=cmd_add)

    s = sub.add_parser("rm", help="remove an agent and rebuild; its Matrix account is locked")
    s.add_argument("name")
    s.add_argument("--purge", action="store_true", help="also delete home, state and secrets, and deactivate the Matrix account for good")
    s.add_argument("--yes", "-y", action="store_true", help="skip confirmation")
    s.add_argument("--no-rebuild", action="store_true", help="remove the registry entry but do not rebuild the host")
    s.set_defaults(func=cmd_rm)

    s = sub.add_parser("purge", help="delete what `rm` left behind for an agent that no longer exists, and deactivate its Matrix account")
    s.add_argument("name")
    s.add_argument("--yes", "-y", action="store_true", help="skip confirmation")
    s.set_defaults(func=cmd_purge)

    for name, help_ in (("start", "start an agent, or all with --all"), ("stop", "stop an agent, or all with --all"), ("restart", "restart an agent, or all with --all")):
        s = sub.add_parser(name, help=help_)
        s.add_argument("name", nargs="?")
        s.add_argument("--all", action="store_true", help="every enabled agent")
        s.set_defaults(func=cmd_lifecycle)

    s = sub.add_parser("status", help="service status for one agent, or a table for all")
    s.add_argument("name", nargs="?")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("logs", help="show the agent's journal")
    s.add_argument("name")
    s.add_argument("-f", "--follow", action="store_true")
    s.add_argument("-n", "--lines", type=int, default=100)
    s.set_defaults(func=cmd_logs)

    s = sub.add_parser(
        "matrix",
        help="the fleet's Matrix server and the agents' accounts",
        description="Drive the fleet's Matrix server (Synapse) and the agents' accounts on it. Without a subcommand: status.",
    )
    ms = s.add_subparsers(dest="sub", metavar="<subcommand>")
    ms.add_parser("status", help="homeserver, admin account, and every agent's account state")
    ms.add_parser("check", help="can the internet reach this server: DNS, TLS, proxy routes, .well-known, federation (no root needed)")
    x = ms.add_parser("introduce", help="(re)send the agent's introduction DM to the operator")
    x.add_argument("name")
    x = ms.add_parser("rotate-token", help="log the agent out everywhere and issue it a new token")
    x.add_argument("name")
    x = ms.add_parser("deactivate", help="permanently deactivate the account of an agent that was removed")
    x.add_argument("name")
    ms.add_parser("start", help="start Synapse, the reconciler and every enabled agent")
    ms.add_parser("stop", help="stop Synapse; the reconciler and every agent stop with it")
    ms.add_parser("restart", help="restart Synapse; the reconciler and every agent restart with it")
    x = ms.add_parser("logs", help="journal of Synapse and the reconciler")
    x.add_argument("-f", "--follow", action="store_true")
    x.add_argument("-n", "--lines", type=int, default=100)
    s.set_defaults(func=cmd_matrix)

    s = sub.add_parser("secrets", help="manage the agent's provider keys")
    ss = s.add_subparsers(dest="sub", metavar="<set|edit|list>")
    ss.required = True
    x = ss.add_parser("set", help="create or update secrets; a bare KEY is prompted for; restarts a running agent")
    x.add_argument("name")
    x.add_argument("pairs", nargs="+", metavar="KEY[=VALUE]")
    x = ss.add_parser("edit", help="open the secrets file in $EDITOR")
    x.add_argument("name")
    x = ss.add_parser("list", help="print secret names, never values")
    x.add_argument("name")
    s.set_defaults(func=cmd_secrets)
    return p


def main():
    args = build_parser().parse_args()
    state = load_state()
    args.func(state, args)


if __name__ == "__main__":
    main()
