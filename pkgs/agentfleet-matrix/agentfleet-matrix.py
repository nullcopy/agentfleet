#!/usr/bin/env python3
"""agentfleet-matrix - keep the host's Matrix homeserver in step with the fleet.

Runs as root from agentfleet-matrix.service after every activation, driven by
/etc/agents/matrix.json which the NixOS module renders. It bootstraps an admin
account, gives every declared agent a Matrix user and a fresh access token
(written root-only to <stateDir>/<agent>/matrix.env), introduces new agents to
the operator in a DM, and locks the accounts of agents that disappeared.

Only the Synapse admin API and the plain client API are used (stdlib only).
"""

import argparse
import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SPEC_PATH = os.environ.get("AGENTFLEET_MATRIX_SPEC", "/etc/agents/matrix.json")
DEVICE_ID = "AGENTFLEET"


def log(msg):
    print(f"agentfleet-matrix: {msg}", flush=True)


def die(msg, code=1):
    print(f"agentfleet-matrix: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body
        try:
            self.errcode = json.loads(body).get("errcode")
        except Exception:
            self.errcode = None


def api(base, method, path, body=None, token=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, e.read().decode(errors="replace"))


def wait_for_homeserver(base, seconds=180):
    deadline = time.monotonic() + seconds
    while True:
        try:
            v = api(base, "GET", "/_matrix/client/versions")
            return v
        except (urllib.error.URLError, ApiError, OSError) as e:
            if time.monotonic() > deadline:
                die(f"homeserver at {base} not reachable: {e}")
            time.sleep(2)


def quote(s):
    return urllib.parse.quote(s, safe="")


# ----------------------------------------------------------------------------
# state
# ----------------------------------------------------------------------------
def load_spec():
    try:
        with open(SPEC_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        die(f"{SPEC_PATH} not found; is services.agentfleet.matrix enabled?")


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_private(path, text, mode=0o600):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def write_json(path, obj):
    write_private(path, json.dumps(obj, indent=2) + "\n")


def record_path(spec, name):
    return os.path.join(spec["stateDir"], "agents", f"{name}.json")


def all_records(spec):
    d = os.path.join(spec["stateDir"], "agents")
    out = {}
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".json"):
                out[fn[:-5]] = read_json(os.path.join(d, fn), {})
    return out


def registration_secret(spec):
    # synapse-secrets.yaml holds exactly one line: registration_shared_secret: "..."
    with open(os.path.join(spec["stateDir"], "synapse-secrets.yaml")) as f:
        for line in f:
            if line.startswith("registration_shared_secret:"):
                return line.split(":", 1)[1].strip().strip('"')
    die("registration_shared_secret missing from synapse-secrets.yaml")


def env_quote(v):
    return '"' + "".join("\\" + c if c in '\\"$`' else c for c in v) + '"'


# ----------------------------------------------------------------------------
# Synapse
# ----------------------------------------------------------------------------
class Synapse:
    def __init__(self, spec):
        self.spec = spec
        self.base = spec["clientUrl"]
        self.server = spec["serverName"]
        self.admin = None

    def user_id(self, localpart):
        return f"@{localpart}:{self.server}"

    # -- bootstrap -------------------------------------------------------------
    def ensure_admin(self):
        path = os.path.join(self.spec["stateDir"], "admin.json")
        rec = read_json(path)
        if rec and self._token_ok(rec["access_token"]):
            self.admin = rec
            return
        uid = self.user_id(self.spec["adminLocalpart"])
        password = secrets.token_urlsafe(32)
        try:
            tok = self._register_shared_secret(self.spec["adminLocalpart"], password, admin=True)
        except ApiError as e:
            if e.errcode != "M_USER_IN_USE":
                raise
            # Admin exists but we lost its token: log in with a password we cannot
            # know. Nothing in the admin API helps without a token, so fail loudly.
            die(f"admin account {uid} exists but {path} is missing; restore it or reset the account")
        self.admin = {"user_id": tok["user_id"], "access_token": tok["access_token"]}
        write_json(path, self.admin)
        log(f"created admin account {uid}")

    def _token_ok(self, token):
        try:
            api(self.base, "GET", "/_matrix/client/v3/account/whoami", token=token)
            return True
        except ApiError:
            return False

    def _register_shared_secret(self, localpart, password, admin=False):
        secret = registration_secret(self.spec)
        nonce = api(self.base, "GET", "/_synapse/admin/v1/register")["nonce"]
        # HMAC-SHA1 over nonce, user, password, admin flag, NUL-separated.
        mac = hmac.new(secret.encode(), digestmod=hashlib.sha1)
        mac.update(b"\x00".join([nonce.encode(), localpart.encode(), password.encode(),
                                 b"admin" if admin else b"notadmin"]))
        return api(self.base, "POST", "/_synapse/admin/v1/register", {
            "nonce": nonce, "username": localpart, "password": password,
            "admin": admin, "mac": mac.hexdigest(),
        })

    # -- admin API -------------------------------------------------------------
    def a(self, method, path, body=None):
        return api(self.base, method, path, body, token=self.admin["access_token"])

    def get_user(self, uid):
        try:
            return self.a("GET", f"/_synapse/admin/v2/users/{quote(uid)}")
        except ApiError as e:
            if e.status == 404:
                return None
            raise

    def ensure_user(self, uid, displayname):
        """Create the account if needed, make sure it is unlocked, and return a
        fresh access token bound to a stable device id."""
        info = self.get_user(uid)
        if info and info.get("deactivated"):
            die(f"{uid} is deactivated; Synapse never reuses such ids. Set matrix.localpart to a new name for this agent")
        password = secrets.token_urlsafe(32)
        body = {"password": password, "logout_devices": False}
        if info is None:
            body.update({"displayname": displayname, "admin": False})
        elif info.get("locked"):
            body["locked"] = False
        self.a("PUT", f"/_synapse/admin/v2/users/{quote(uid)}", body)
        if info is None:
            log(f"created {uid}")
        elif info.get("locked"):
            log(f"unlocked {uid}")
        try:
            self.a("POST", f"/_synapse/admin/v1/users/{quote(uid)}/override_ratelimit",
                   {"messages_per_second": 0, "burst_count": 0})
        except ApiError as e:
            log(f"warning: could not lift rate limit for {uid}: {e}")
        login = api(self.base, "POST", "/_matrix/client/v3/login", {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": uid},
            "password": password,
            "device_id": DEVICE_ID,
            "initial_device_display_name": "agentfleet",
        })
        return login["access_token"], login.get("device_id", DEVICE_ID)

    def logout_everything(self, uid):
        devs = self.a("GET", f"/_synapse/admin/v2/users/{quote(uid)}/devices").get("devices", [])
        ids = [d["device_id"] for d in devs]
        if ids:
            self.a("POST", f"/_synapse/admin/v2/users/{quote(uid)}/delete_devices", {"devices": ids})

    def lock(self, uid):
        if self.get_user(uid) is None:
            log(f"warning: {uid} does not exist on the homeserver; nothing to lock")
            return
        self.a("PUT", f"/_synapse/admin/v2/users/{quote(uid)}", {"locked": True})
        self.logout_everything(uid)

    def deactivate(self, uid):
        if self.get_user(uid) is None:
            log(f"warning: {uid} does not exist on the homeserver; nothing to deactivate")
            return
        self.a("POST", f"/_synapse/admin/v1/deactivate/{quote(uid)}", {"erase": False})

    # -- as the agent ----------------------------------------------------------
    def introduce(self, token, uid, operator, text, html):
        room = api(self.base, "POST", "/_matrix/client/v3/createRoom", {
            "preset": "trusted_private_chat",
            "is_direct": True,
            "invite": [operator],
        }, token=token)["room_id"]
        try:
            direct = api(self.base, "GET", f"/_matrix/client/v3/user/{quote(uid)}/account_data/m.direct", token=token)
        except ApiError as e:
            if e.status != 404:
                raise
            direct = {}
        direct.setdefault(operator, [])
        if room not in direct[operator]:
            direct[operator].append(room)
        api(self.base, "PUT", f"/_matrix/client/v3/user/{quote(uid)}/account_data/m.direct", direct, token=token)
        api(self.base, "PUT", f"/_matrix/client/v3/rooms/{quote(room)}/send/m.room.message/{secrets.token_hex(8)}", {
            "msgtype": "m.text", "body": text,
            "format": "org.matrix.custom.html", "formatted_body": html,
        }, token=token)
        return room


# ----------------------------------------------------------------------------
# reconcile
# ----------------------------------------------------------------------------
def intro_message(spec, name, a):
    desc = a.get("description") or ""
    model = a.get("model") or "default model"
    text = (
        f"Hello! I'm {name}, a {a['harness']} agent running on {spec['hostName']} ({model})."
        + (f" {desc[0].upper() + desc[1:]}." if desc else "")
        + f" This room is our direct line: message me here any time. "
        f"In other rooms, invite me and mention @{a['localpart']} to get my attention."
    )
    html = (
        f"Hello! I'm <b>{name}</b>, a {a['harness']} agent running on <code>{spec['hostName']}</code> ({model})."
        + (f" {desc[0].upper() + desc[1:]}." if desc else "")
        + f" This room is our direct line: message me here any time. "
        f"In other rooms, invite me and mention <code>@{a['localpart']}</code> to get my attention."
    )
    return text, html


def write_env(a, token, device):
    write_private(a["envFile"], (
        "# Written by agentfleet-matrix; replaced on every reconcile that rotates the token.\n"
        f"MATRIX_ACCESS_TOKEN={env_quote(token)}\n"
        f"MATRIX_DEVICE_ID={env_quote(device)}\n"
    ), mode=0o400)


def service_active(unit):
    if not unit:
        return False
    r = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True)
    return r.stdout.strip() == "active"


def provision(syn, spec, name, a, rec, force_token=False):
    uid = a["userId"]
    have_env = os.path.exists(a["envFile"])
    fresh = rec.get("state") != "active" or rec.get("user_id") != uid or not have_env or force_token
    if fresh:
        token, device = syn.ensure_user(uid, name)
        write_env(a, token, device)
        rec.update({"user_id": uid, "device_id": device, "state": "active", "updated": int(time.time())})
        write_json(record_path(spec, name), rec)
        log(f"{name}: token written to {a['envFile']}")
        if service_active(a.get("service")):
            subprocess.run(["systemctl", "restart", a["service"]], check=False)
            log(f"{name}: restarted {a['service']}")
    if a.get("introduce") and spec.get("operator") and not rec.get("introduced_room"):
        token = read_token(a["envFile"])
        text, html = intro_message(spec, name, a)
        try:
            room = syn.introduce(token, uid, spec["operator"], text, html)
        except ApiError as e:
            log(f"{name}: could not introduce to {spec['operator']} yet ({e.errcode or e.status}); will retry next run. "
                f"If the operator is on another homeserver, federation must be working.")
            return
        rec.update({"introduced_room": room, "introduced_at": int(time.time())})
        write_json(record_path(spec, name), rec)
        log(f"{name}: introduced to {spec['operator']} in {room}")


def read_token(env_file):
    with open(env_file) as f:
        for line in f:
            if line.startswith("MATRIX_ACCESS_TOKEN="):
                v = line.split("=", 1)[1].strip()
                return v[1:-1].replace('\\"', '"').replace("\\\\", "\\") if v.startswith('"') else v
    die(f"no MATRIX_ACCESS_TOKEN in {env_file}")


def cmd_reconcile(spec, args):
    wait_for_homeserver(spec["clientUrl"])
    syn = Synapse(spec)
    syn.ensure_admin()
    records = all_records(spec)
    for name, a in sorted(spec["agents"].items()):
        provision(syn, spec, name, a, records.get(name, {}))
    for name, rec in records.items():
        if name in spec["agents"] or rec.get("state") != "active":
            continue
        syn.lock(rec["user_id"])
        rec["state"] = "locked"
        write_json(record_path(spec, name), rec)
        log(f"{name}: agent gone, locked {rec['user_id']} and logged out its devices")


def cmd_status(spec, args):
    try:
        v = api(spec["clientUrl"], "GET", "/_matrix/client/versions")
        print(f"homeserver {spec['clientUrl']} ({spec['serverName']}): up, spec versions {len(v.get('versions', []))}")
    except Exception as e:
        print(f"homeserver {spec['clientUrl']}: DOWN ({e})")
    admin = read_json(os.path.join(spec["stateDir"], "admin.json"))
    print(f"admin: {admin['user_id'] if admin else 'not bootstrapped'}")
    print(f"operator: {spec.get('operator') or '-'}")
    recs = all_records(spec)
    names = sorted(set(recs) | set(spec["agents"]))
    if not names:
        print("no matrix agents")
        return
    print(f"{'AGENT':<16} {'USER':<40} {'STATE':<12} INTRODUCED")
    for n in names:
        r = recs.get(n, {})
        uid = r.get("user_id") or spec["agents"].get(n, {}).get("userId", "")
        print(f"{n:<16} {uid:<40} {r.get('state', 'pending'):<12} {r.get('introduced_room') or '-'}")


def _spec_agent(spec, name):
    a = spec["agents"].get(name)
    if a is None:
        die(f"agent '{name}' is not a Matrix-enabled agent on this host")
    return a


def cmd_introduce(spec, args):
    a = _spec_agent(spec, args.name)
    syn = Synapse(spec)
    syn.ensure_admin()
    rec = read_json(record_path(spec, args.name), {})
    rec.pop("introduced_room", None)
    provision(syn, spec, args.name, a, rec)


def cmd_rotate(spec, args):
    a = _spec_agent(spec, args.name)
    syn = Synapse(spec)
    syn.ensure_admin()
    rec = read_json(record_path(spec, args.name), {})
    syn.logout_everything(a["userId"])
    provision(syn, spec, args.name, a, rec, force_token=True)


def cmd_deactivate(spec, args):
    if args.name in spec["agents"]:
        die(f"agent '{args.name}' still exists; remove it first (agentctl rm)")
    rec = read_json(record_path(spec, args.name))
    if not rec:
        die(f"no Matrix record for '{args.name}'")
    if rec.get("state") == "deactivated":
        print(f"{rec['user_id']} already deactivated")
        return
    syn = Synapse(spec)
    syn.ensure_admin()
    syn.deactivate(rec["user_id"])
    rec["state"] = "deactivated"
    write_json(record_path(spec, args.name), rec)
    log(f"deactivated {rec['user_id']} (this id can never be registered again)")


def cmd_register_user(spec, args):
    """Create an ordinary (or admin) human account on this homeserver and print
    its access token. Handy for an operator account on the agents' own server."""
    syn = Synapse(spec)
    password = args.password or secrets.token_urlsafe(24)
    tok = syn._register_shared_secret(args.localpart, password, admin=args.admin)
    print(json.dumps({"user_id": tok["user_id"], "access_token": tok["access_token"],
                      "password": password if not args.password else "(as given)"}, indent=2))


def main():
    p = argparse.ArgumentParser(prog="agentfleet-matrix", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", metavar="<command>")
    sub.required = True
    sub.add_parser("reconcile", help="provision declared agents, lock vanished ones (run by the unit)").set_defaults(func=cmd_reconcile)
    sub.add_parser("status", help="homeserver, admin and per-agent account state").set_defaults(func=cmd_status)
    s = sub.add_parser("introduce", help="(re)send the agent's introduction DM to the operator")
    s.add_argument("name")
    s.set_defaults(func=cmd_introduce)
    s = sub.add_parser("rotate-token", help="log out every session of the agent and issue a new token")
    s.add_argument("name")
    s.set_defaults(func=cmd_rotate)
    s = sub.add_parser("deactivate", help="permanently deactivate a removed agent's account")
    s.add_argument("name")
    s.set_defaults(func=cmd_deactivate)
    s = sub.add_parser("register-user", help="create a human account on this homeserver (prints its token)")
    s.add_argument("localpart")
    s.add_argument("--admin", action="store_true")
    s.add_argument("--password")
    s.set_defaults(func=cmd_register_user)
    args = p.parse_args()
    if os.geteuid() != 0:
        die("must run as root")
    args.func(load_spec(), args)


if __name__ == "__main__":
    main()
