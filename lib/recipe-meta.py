#!/usr/bin/env python3
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def http_status(url, insecure):
    context = ssl._create_unverified_context() if insecure else ssl.create_default_context()
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=context))
    try:
        with opener.open(urllib.request.Request(url, method="GET"), timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as err:
        return err.code
    except Exception:
        return 0


def healthy(check):
    if check.get("type") == "tcp":
        try:
            with socket.create_connection(("127.0.0.1", int(check["port"])), timeout=3):
                return True
        except OSError:
            return False
    status = http_status(check["url"], bool(check.get("insecureTls")))
    if status == 0:
        return False
    expected = check.get("expectStatus")
    if expected:
        return status in expected
    return status < 500


def read_values(path, declared):
    allowed = {entry["key"] for entry in declared}
    values = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key in allowed and value != "":
                    values[key] = value[:4096]
    return values


def cmd_list(root):
    for slug in sorted(os.listdir(root)):
        path = os.path.join(root, slug, "recipe.json")
        if os.path.isfile(path):
            meta = load(path)
            print("%-20s %-28s %s" % (slug, meta["name"], meta["appVersion"]))
    return 0


def cmd_field(path, name):
    value = load(path).get(name, "")
    print(str(value).lower() if isinstance(value, bool) else value)
    return 0


def cmd_health(path, timeout):
    check = load(path).get("healthCheck") or {}
    deadline = time.monotonic() + int(timeout)
    while time.monotonic() < deadline:
        if healthy(check):
            return 0
        time.sleep(3)
    return 1


def cmd_outputs(path, outfile, secrets_file):
    declared = load(path).get("outputs") or []
    values = read_values(outfile, declared)
    missing = [e["key"] for e in declared if e.get("required", True) and e["key"] not in values]
    if missing:
        print("missing required outputs: " + ", ".join(missing), file=sys.stderr)
        return 1
    lines = []
    for entry in declared:
        if entry["key"] in values:
            lines.append((entry["label"], values[entry["key"]], bool(entry.get("secret"))))
    plain = [line for line in lines if not line[2]]
    secret = [line for line in lines if line[2]]
    for label, value, _ in plain:
        print("%s: %s" % (label, value))
    if secret and secrets_file:
        fd = os.open(secrets_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            for label, value, _ in lines:
                handle.write("%s: %s\n" % (label, value))
        os.chmod(secrets_file, 0o600)
        print("Credentials written to %s (root only)" % secrets_file)
    else:
        for label, value, _ in secret:
            print("%s: %s" % (label, value))
    return 0


def main(argv):
    if len(argv) < 2:
        return 2
    command, args = argv[1], argv[2:]
    if command == "list":
        return cmd_list(*args)
    if command == "field":
        return cmd_field(*args)
    if command == "health":
        return cmd_health(*args)
    if command == "outputs":
        return cmd_outputs(args[0], args[1], args[2] if len(args) > 2 else "")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
