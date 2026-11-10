#!/usr/bin/env python3
"""Render the DR host's .env from SSM Parameter Store SecureStrings (aws provider).

Every parameter under --prefix becomes KEY=value (KEY = last path segment). The host of
DATABASE_URL / MIGRATION_DATABASE_URL is replaced with the promoted endpoint. The file is
written atomically with mode 600. Values are never printed.
"""
import argparse, json, os, subprocess, sys, tempfile
from urllib.parse import urlsplit, urlunsplit

ap = argparse.ArgumentParser()
ap.add_argument("--region", required=True)
ap.add_argument("--prefix", required=True)
ap.add_argument("--db-host", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()

raw = subprocess.run(
    ["aws", "ssm", "get-parameters-by-path", "--region", a.region, "--path", a.prefix,
     "--with-decryption", "--recursive", "--output", "json"],
    check=True, capture_output=True, text=True).stdout
params = {p["Name"].rsplit("/", 1)[-1]: p["Value"] for p in json.loads(raw)["Parameters"]}
for required in ("DATABASE_URL", "REDIS_PASSWORD"):
    if required not in params:
        sys.exit(f"ERROR: SSM parameter {a.prefix}{required} is missing")

def rehost(url: str) -> str:
    u = urlsplit(url)
    userinfo = u.netloc.rsplit("@", 1)[0]
    return urlunsplit(u._replace(netloc=f"{userinfo}@{a.db_host}:{u.port or 5432}"))

for key in ("DATABASE_URL", "MIGRATION_DATABASE_URL"):
    if key in params:
        params[key] = rehost(params[key])

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(a.out)), prefix=".env.")
with os.fdopen(fd, "w") as f:
    for k, v in sorted(params.items()):
        f.write(f'{k}="{v}"\n')
os.chmod(tmp, 0o600)
os.replace(tmp, a.out)
print(f"rendered {len(params)} variables to {a.out} (values not shown)")
