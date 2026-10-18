#!/usr/bin/env python3
"""agentctl - create, run and destroy the Hermes agents on this host (agentfleet).

Agents are runtime state, not NixOS configuration: `add` creates a system
user, a home, a state directory with agent.json, the secrets and the Matrix
token, and starts one instance of the agent@.service template. Nothing is
rebuilt. The NixOS module renders what agentctl needs to know about the host
to /etc/agents/state.json; agentctl shells out to systemd, the shadow tools
and agentfleet-matrix for the rest.
"""

import argparse
import getpass
import grp
import json
import os
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

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


def run(cmd, check=True, capture=False, **kw):
    r = subprocess.run(cmd, check=False, text=True, capture_output=capture, **kw)
    if check and r.returncode != 0:
        detail = (r.stderr or "").strip() if capture else ""
        die(f"`{' '.join(cmd)}` failed (exit {r.returncode})" + (f": {detail}" if detail else ""), r.returncode)
    return r


def systemctl(*args, check=True, capture=False):
    return run(["systemctl", *args], check=check, capture=capture)


def is_active(unit):
    return systemctl("is-active", unit, check=False, capture=True).stdout.strip() == "active"


def unit_state(unit):
    return systemctl("is-active", unit, check=False, capture=True).stdout.strip() or "unknown"


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


def user_exists(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


# ----------------------------------------------------------------------------
# layout
# ----------------------------------------------------------------------------
class Agent:
    """Paths and names for one agent; `data` is agent.json if it exists."""

    def __init__(self, state, name):
        self.name = name
        self.user = f"{state['userPrefix']}{name}"
        self.home = os.path.join(state["homeBase"], name)
        self.state_dir = os.path.join(state["stateDir"], name)
        self.json_path = os.path.join(self.state_dir, "agent.json")
        self.secrets_file = os.path.join(self.state_dir, "secrets.env")
        self.environment_file = os.path.join(self.state_dir, "environment.env")
        self.matrix_env = os.path.join(self.state_dir, "matrix.env")
        self.unit = state["unitTemplate"] % name
        self.data = read_json(self.json_path) or {}

    @property
    def exists(self):
        return bool(self.data)

    @property
    def removed(self):
        return self.data.get("state") == "removed"

    @property
    def active(self):
        return self.exists and not self.removed

    def save(self):
        write_json(self.json_path, self.data)


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj, mode=0o600):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def all_agents(state):
    base = state["stateDir"]
    pattern = state.get("nameRegex", DEFAULT_NAME_REGEX)
    out = {}
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for n in names:
        if re.fullmatch(pattern, n) and os.path.isdir(os.path.join(base, n)):
            out[n] = Agent(state, n)
    return out


def get_agent(state, name, allow_removed=False):
    a = Agent(state, name)
    if not a.exists or (a.removed and not allow_removed):
        die(f"no agent named '{name}' (see `agentctl list`)")
    return a


def matrix_record(state, name):
    return read_json(os.path.join(state["matrix"]["stateDir"], "agents", f"{name}.json")) or {}


def matrix_ctl(state, *args, check=True, capture=False):
    return run([state["matrix"]["ctl"], *args], check=check, capture=capture)


# ----------------------------------------------------------------------------
# env files (KEY="VALUE", root-owned 0400; the systemd EnvironmentFile dialect)
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


def write_env_file(path, values, header="# Managed by agentctl. KEY=\"VALUE\", one per line."):
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".env.")
        with os.fdopen(fd, "w") as f:
            f.write(header + "\n")
            for k, v in sorted(values.items()):
                f.write(f"{k}={env_quote(v)}\n")
        os.chmod(tmp, 0o400)
        os.chown(tmp, 0, 0)
        os.replace(tmp, path)
    except OSError as e:
        die(f"cannot write {path}: {e.strerror}")


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
    """Secrets for a new agent: one provider key is enough."""
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


_SECRET_LIKE = re.compile(r".*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL).*")


def secret_like(key):
    u = key.upper()
    return bool(_SECRET_LIKE.match(u)) and not u.endswith("_ENV")


def refuse_secrets(name, keys):
    """Credentials belong in secrets.env, where `secrets list` shows them and
    nothing else does; a credential-looking name elsewhere is a mistake."""
    bad = [k for k in keys if secret_like(k.rsplit(".", 1)[-1])]
    if bad:
        hint = (
            f"use --secret {bad[0]} (or `agentctl secrets set {name} {bad[0]}`)"
            if "." not in bad[0]
            else f"store the value with --secret <NAME> and point Hermes at it with --set {bad[0]}_env=<NAME>"
        )
        die(f"{', '.join(bad)} look(s) like a secret; {hint} instead")


# ----------------------------------------------------------------------------
# Hermes settings (--set) and config.yaml seeding
# ----------------------------------------------------------------------------
def coerce(v):
    """Turn a --set value into a literal when it round-trips exactly (so
    "0123" and "1_000" stay strings); --set-str forces a string."""
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


def parse_settings(name, sets, set_strs):
    settings = {}
    for item, literal in [(x, True) for x in sets or []] + [(x, False) for x in set_strs or []]:
        if "=" not in item:
            die(f"--set expects key=value, got '{item}'")
        k, v = item.split("=", 1)
        refuse_secrets(name, [k])
        set_nested(settings, k, coerce(v) if literal else v)
    return settings


def deep_merge(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def seed_hermes_config(a):
    """~/.hermes/config.yaml from model and settings, once. Hermes rewrites
    the file at runtime, so an existing one is left alone. YAML is a superset
    of JSON."""
    path = os.path.join(a.home, ".hermes", "config.yaml")
    if os.path.exists(path):
        return False
    cfg = {}
    if a.data.get("model"):
        cfg = {"model": {"default": a.data["model"]}}
    cfg = deep_merge(cfg, a.data.get("settings") or {})
    pw = pwd.getpwnam(a.user)
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o750, exist_ok=True)
    os.chown(d, pw.pw_uid, pw.pw_gid)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)
    os.chown(path, pw.pw_uid, pw.pw_gid)
    return True


# ----------------------------------------------------------------------------
# users, homes, limits
# ----------------------------------------------------------------------------
def create_user(state, a):
    if user_exists(a.user):
        return
    run([
        "useradd", "--system", "--user-group", "--no-create-home",
        "--home-dir", a.home, "--shell", state["nologin"],
        "--comment", f"agentfleet agent {a.name}", a.user,
    ], capture=True)


def delete_user(a):
    if user_exists(a.user):
        run(["userdel", a.user], check=False, capture=True)
    try:
        grp.getgrnam(a.user)
        run(["groupdel", a.user], check=False, capture=True)
    except KeyError:
        pass


def create_home(a):
    pw = pwd.getpwnam(a.user)
    os.makedirs(a.home, mode=0o750, exist_ok=True)
    os.chmod(a.home, 0o750)
    os.chown(a.home, pw.pw_uid, pw.pw_gid)
    os.makedirs(a.state_dir, mode=0o700, exist_ok=True)
    os.chmod(a.state_dir, 0o700)


def apply_limits(a):
    """MemoryMax/CPUQuota as a persistent per-instance drop-in."""
    props = []
    props.append(f"MemoryMax={a.data['memory_max'] if a.data.get('memory_max') else 'infinity'}")
    props.append(f"CPUQuota={a.data['cpu_quota'] if a.data.get('cpu_quota') else ''}")
    systemctl("set-property", a.unit, *props, check=False, capture=True)


# ----------------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------------
def cmd_names(state, args):
    """Used by shell completion."""
    agents = all_agents(state)
    names = [n for n, a in agents.items() if (a.removed if args.removed else a.active)]
    print("\n".join(names))


def cmd_list(state, args):
    rows = []
    for name, a in all_agents(state).items():
        rec = matrix_record(state, name)
        uid = rec.get("user_id") or f"@{a.data.get('localpart') or name}:{state['matrix']['serverName']}"
        if a.removed:
            rows.append((name, "removed", uid, a.data.get("model") or "", "files kept; `agentctl add` resumes, `agentctl purge` deletes"))
        elif a.exists:
            rows.append((name, unit_state(a.unit), uid, a.data.get("model") or "", a.data.get("description", "")))
        else:
            rows.append((name, "orphan", "", "", "directory without agent.json; `agentctl purge` deletes it"))
    if not rows:
        print("no agents")
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
    a = Agent(state, name)
    if a.active:
        die(f"agent '{name}' already exists")
    if matrix_record(state, name).get("state") in ("purged", "deactivated"):
        die(f"the name '{name}' was purged (agentctl rm --purge) and can never be used again; pick another name")
    resuming = a.removed
    if not resuming and user_exists(a.user):
        die(f"user {a.user} already exists on this host but is not an agent; remove it first")
    if not resuming and os.path.exists(a.home):
        die(f"{a.home} already exists; `agentctl purge {name}` removes leftovers")

    env = parse_kv(args.env, "--env")
    refuse_secrets(name, env)
    settings = parse_settings(name, args.set, args.set_str)
    provided = parse_kv(args.secret, "--secret", prompt=True)
    secrets = provided if resuming else prompt_secrets(state, provided, args.no_prompt)

    # agent.json: on resume, flags given now override what was there.
    data = a.data if resuming else {"name": name, "created": int(time.time()), "localpart": name}
    for key, val in (("model", args.model), ("description", args.description),
                     ("memory_max", args.memory_max), ("cpu_quota", args.cpu_quota)):
        if val is not None:
            data[key] = val
    data.setdefault("description", "")
    if env:
        data["environment"] = {**data.get("environment", {}), **env}
    if settings:
        data["settings"] = deep_merge(data.get("settings", {}), settings)
    data["state"] = "active"
    a.data = data

    create_user(state, a)
    create_home(a)
    a.save()
    write_env_file(a.environment_file, data.get("environment", {}), header="# Managed by agentctl: the agent's non-secret environment.")
    if secrets or not os.path.exists(a.secrets_file):
        write_env_file(a.secrets_file, {**read_env_file(a.secrets_file), **secrets})
    if secrets:
        print(f"wrote {len(secrets)} secret(s) to {a.secrets_file}")
    if seed_hermes_config(a):
        print(f"seeded {a.home}/.hermes/config.yaml")
    apply_limits(a)
    print(("resumed" if resuming else "created") + f" agent '{name}' ({a.user}, {a.home})")

    # Matrix account, token, introduction. Failures here leave the agent in
    # place without a token; `agentctl matrix introduce` finishes the job.
    r = matrix_ctl(state, "provision", name, check=False)
    if r.returncode != 0:
        warn(f"Matrix provisioning failed; the agent is created but cannot start without its token. "
             f"Check `agentctl matrix status` / `agentctl matrix check`, then `agentctl matrix introduce {name}` and `agentctl start {name}`.")
        sys.exit(1)

    if args.no_start:
        print(f"not started (--no-start); `agentctl start {name}` when ready")
        return
    systemctl("start", a.unit)
    report_started(state, a)


def report_started(state, a):
    time.sleep(1)
    if not is_active(a.unit):
        warn(f"agent '{a.name}' did not stay up ({unit_state(a.unit)}); see `agentctl logs {a.name}`")
        sys.exit(1)
    rec = matrix_record(state, a.name)
    operator = state["matrix"]["operator"]
    if rec.get("introduced_room"):
        print(f"agent '{a.name}' is up and has invited {operator} to {rec['introduced_room']}. Accept the invite in your Matrix client.")
    else:
        warn(f"agent '{a.name}' is up, but its invitation to {operator} could not be delivered.")
        warn(f"Run `agentctl matrix check` to see what is wrong; `agentctl matrix introduce {a.name}` retries the invite.")
    print(f"Next: agentctl logs {a.name} -f")


def cmd_rm(state, args):
    need_root()
    a = Agent(state, args.name)
    leftovers = os.path.isdir(a.home) or os.path.isdir(a.state_dir)
    if not a.exists and not (args.purge and leftovers):
        die(f"no agent named '{args.name}' (see `agentctl list`)")
    if a.removed and not args.purge:
        die(f"agent '{args.name}' is already removed; `agentctl purge {args.name}` deletes what is left")
    if not args.yes:
        what = (
            "and PURGE it: delete home, state and secrets, leave its rooms, and retire the name for good"
            if args.purge
            else "(home, state and Matrix account are kept; `agentctl add` with the same name resumes it)"
        )
        if not confirm(f"Remove agent '{args.name}' {what}?"):
            die("aborted", 2)

    if is_active(a.unit):
        systemctl("stop", a.unit)
        print(f"stopped {a.unit}")

    if not args.purge:
        a.data["state"] = "removed"
        a.data["removed"] = int(time.time())
        a.save()
        matrix_ctl(state, "lock", args.name, check=False)
        print(f"agent '{args.name}' removed; its files and Matrix account are kept")
        return

    for p in (a.home, a.state_dir):
        if os.path.isdir(p):
            shutil.rmtree(p)
            print(f"deleted {p}")
    delete_user(a)
    systemctl("revert", a.unit, check=False, capture=True)  # drop the limits drop-in
    r = matrix_ctl(state, "purge", args.name, check=False, capture=True)
    out = (r.stdout + r.stderr).strip()
    if out:
        print(out)
    print(f"agent '{args.name}' purged; the name can never be used again")


def cmd_purge(state, args):
    args.purge = True
    cmd_rm(state, args)


def active_units(state):
    return [a.unit for a in all_agents(state).values() if a.active]


def cmd_lifecycle(state, args):
    need_root()
    if args.all:
        units = active_units(state)
        if not units:
            if not args.quiet:
                print("no agents")
            return
        systemctl(args.command, *units)
        if not args.quiet:
            print(f"{args.command}: {len(units)} agent(s)")
        return
    if not args.name:
        die(f"agentctl {args.command}: give an agent name or --all")
    a = get_agent(state, args.name)
    systemctl(args.command, a.unit)


def cmd_status(state, args):
    if not args.name:
        return cmd_list(state, args)
    a = get_agent(state, args.name)
    systemctl("status", "--no-pager", "--lines=0", a.unit, check=False)


def cmd_logs(state, args):
    a = get_agent(state, args.name, allow_removed=True)
    cmd = ["journalctl", "-f" if args.follow else "--no-pager", "-n", str(args.lines), "-u", a.unit]
    os.execvp("journalctl", cmd)


def cmd_matrix(state, args):
    m = state["matrix"]
    synapse, reconcile = m["synapseService"], m["reconcileService"]
    sub = args.sub or "status"
    if sub != "check":
        need_root()
    if sub in ("status", "check", "introduce", "rotate-token"):
        ctl = m["ctl"]
        extra = [args.name] if getattr(args, "name", None) else []
        os.execvp(ctl, [ctl, sub, *extra])
    if sub == "stop":
        # Agents require the server; systemd stops them with it.
        systemctl("stop", synapse)
        print(f"stopped {synapse} and, with it, every agent")
    elif sub == "start":
        systemctl("start", synapse, reconcile, *active_units(state))
        print(f"started {synapse}, {reconcile} and every agent")
    elif sub == "restart":
        # Restart propagates through Requires= to the agents.
        systemctl("restart", synapse)
        print(f"restarted {synapse}; the agents followed")
    elif sub == "logs":
        cmd = ["journalctl", "-f" if args.follow else "--no-pager", "-n", str(args.lines), "-u", synapse, "-u", reconcile]
        os.execvp("journalctl", cmd)


def cmd_secrets(state, args):
    need_root()
    a = get_agent(state, args.name, allow_removed=True)
    path = a.secrets_file
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
    if is_active(a.unit):
        systemctl("restart", a.unit)
        print(f"restarted {a.unit}")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(
        prog="agentctl",
        description="Create, run and destroy the Hermes agents on this host. Each agent is its own Unix user with its own Matrix account.",
        epilog="Host facts come from %s (override with $AGENTCTL_STATE)." % STATE_PATH,
    )
    sub = p.add_subparsers(dest="command", metavar="<command>")
    sub.required = True

    s = sub.add_parser("list", help="show all agents, their state and Matrix id")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser(
        "add",
        help="create an agent and start it",
        description="Create an agent: system user, home, secrets, Matrix account, then start it. It introduces itself to you on Matrix. Running `add` for an agent removed with `rm` resumes it.",
    )
    s.add_argument("name")
    s.add_argument("--model", help="Hermes model id, e.g. anthropic/claude-sonnet-5.5")
    s.add_argument("--description", help="free text shown in `agentctl list` and in the introduction")
    s.add_argument("--memory-max", metavar="SIZE", help="systemd MemoryMax, e.g. 4G")
    s.add_argument("--cpu-quota", metavar="PCT", help="systemd CPUQuota, e.g. 200%%")
    s.add_argument("--env", action="append", metavar="K=V", help="non-secret environment variable (repeatable)")
    s.add_argument("--set", action="append", metavar="KEY=VAL", help="Hermes config.yaml key, dotted; integers and true/false become literals (repeatable)")
    s.add_argument("--set-str", action="append", metavar="KEY=VAL", help="like --set but the value is always a string")
    s.add_argument("--secret", action="append", metavar="KEY[=VALUE]", help="a key to store; without =VALUE you are prompted for it, which keeps it out of the shell history (repeatable)")
    s.add_argument("--no-prompt", action="store_true", help="never prompt for the well-known provider keys")
    s.add_argument("--no-start", action="store_true", help="create everything but do not start the agent")
    s.set_defaults(func=cmd_add)

    s = sub.add_parser("rm", help="stop and remove an agent; files and Matrix account are kept unless --purge")
    s.add_argument("name")
    s.add_argument("--purge", action="store_true", help="delete home, state and secrets, leave its rooms, and retire the name for good")
    s.add_argument("--yes", "-y", action="store_true", help="skip confirmation")
    s.set_defaults(func=cmd_rm)

    s = sub.add_parser("purge", help="same as `rm --purge`; also for an agent removed earlier without it")
    s.add_argument("name")
    s.add_argument("--yes", "-y", action="store_true", help="skip confirmation")
    s.set_defaults(func=cmd_purge)

    for name, help_ in (("start", "start an agent, or all with --all"), ("stop", "stop an agent, or all with --all"), ("restart", "restart an agent, or all with --all")):
        s = sub.add_parser(name, help=help_)
        s.add_argument("name", nargs="?")
        s.add_argument("--all", action="store_true", help="every agent")
        s.add_argument("--quiet", action="store_true", help=argparse.SUPPRESS)
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
        help="the fleet's Matrix server and the agents' accounts: status, check, introduce, rotate-token, start, stop, restart, logs",
        description="Drive the fleet's Matrix server (Synapse) and the agents' accounts on it. Without a subcommand: status.",
    )
    ms = s.add_subparsers(dest="sub", metavar="<subcommand>")
    ms.add_parser("status", help="homeserver, admin account, and every agent's account state")
    ms.add_parser("check", help="can the internet reach this server: DNS, TLS, proxy routes, .well-known, federation (no root needed)")
    x = ms.add_parser("introduce", help="(re)send the agent's introduction DM to the operator")
    x.add_argument("name")
    x = ms.add_parser("rotate-token", help="log the agent out everywhere and issue it a new token")
    x.add_argument("name")
    ms.add_parser("start", help="start Synapse, the reconciler and every agent")
    ms.add_parser("stop", help="stop Synapse; every agent stops with it")
    ms.add_parser("restart", help="restart Synapse; every agent restarts with it")
    x = ms.add_parser("logs", help="journal of Synapse and the reconciler")
    x.add_argument("-f", "--follow", action="store_true")
    x.add_argument("-n", "--lines", type=int, default=100)
    s.set_defaults(func=cmd_matrix)

    s = sub.add_parser(
        "secrets",
        help="an agent's provider keys: set, edit, list",
        description="Manage the secrets in /var/lib/agents/<name>/secrets.env: `set` writes keys (prompting for values), `edit` opens the file in $EDITOR, `list` prints the names. set and edit restart a running agent.",
    )
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
    # `names [--removed]` feeds the shell completions. It is handled before
    # argparse so it stays out of --help (argparse.SUPPRESS on a subcommand
    # prints "==SUPPRESS==" in Python 3.14).
    if sys.argv[1:2] == ["names"]:
        flags = sys.argv[2:]
        if flags not in ([], ["--removed"]):
            die("usage: agentctl names [--removed]")
        cmd_names(load_state(), argparse.Namespace(removed=bool(flags)))
        return
    args = build_parser().parse_args()
    state = load_state()
    args.func(state, args)


if __name__ == "__main__":
    main()
