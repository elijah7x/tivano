#!/usr/bin/env bash
# Run as root with the publisher public key as argument. Never opens new network ports.
set -euo pipefail
cd "$(dirname "$0")"
KEY=${1:?publisher public key file required}
python3 - "$KEY" <<'PY'
import pathlib, sys
parts=pathlib.Path(sys.argv[1]).read_text().strip().split()
if len(parts) != 3 or parts[0] != 'ssh-ed25519':
    raise SystemExit('Expected one ed25519 public key with comment')
PY
BACKUP="/var/backups/tivano-mirror/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
cp -a /etc/nginx/conf.d/elijah.ac.cn.conf "$BACKUP/elijah.ac.cn.conf"
for file in /etc/nginx/conf.d/00-tivano-zones.conf /etc/nginx/snippets/tivano-locations.conf; do
    if test -e "$file"; then cp -a "$file" "$BACKUP/$(basename "$file")"; fi
done
rollback() {
    cp -a "$BACKUP/elijah.ac.cn.conf" /etc/nginx/conf.d/elijah.ac.cn.conf
    for file in /etc/nginx/conf.d/00-tivano-zones.conf /etc/nginx/snippets/tivano-locations.conf; do
        if test -e "$BACKUP/$(basename "$file")"; then
            cp -a "$BACKUP/$(basename "$file")" "$file"
        else rm -f "$file"; fi
    done
    nginx -t && systemctl reload nginx
}
trap rollback ERR
if ! id tivano-publisher >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/tivano-publisher --shell /bin/sh tivano-publisher
fi
install -d -m 755 -o tivano-publisher -g tivano-publisher /var/www/tivano /var/www/tivano/releases
install -d -m 700 -o tivano-publisher -g tivano-publisher /var/lib/tivano-publisher/.ssh
install -d -m 755 /usr/local/libexec /etc/nginx/snippets
install -m 644 publish-mirror.py /usr/local/libexec/tivano-publish-mirror.py
python3 - "$KEY" <<'PY'
from pathlib import Path
import os, pwd
key=Path(__import__('sys').argv[1]).read_text().strip()
line='restrict,command="/usr/bin/python3 /usr/local/libexec/tivano-publish-mirror.py" '+key+'\n'
path=Path('/var/lib/tivano-publisher/.ssh/authorized_keys')
if path.exists() and path.read_text() != line:
    raise SystemExit('Existing publisher authorization differs; refusing replacement')
path.write_text(line)
account=pwd.getpwnam('tivano-publisher')
os.chown(path, account.pw_uid, account.pw_gid)
os.chmod(path, 0o600)
PY
install -m 644 tivano-zones.conf /etc/nginx/conf.d/00-tivano-zones.conf
install -m 644 tivano-locations.conf /etc/nginx/snippets/tivano-locations.conf
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/nginx/conf.d/elijah.ac.cn.conf')
s=p.read_text()
include='    include /etc/nginx/snippets/tivano-locations.conf;\n'
if include not in s:
    marker='    root /var/www/elijah.ac.cn;\n    index index.html;\n'
    if s.count(marker) != 1:
        raise SystemExit('Unexpected main vhost layout; refusing modification')
    s=s.replace(marker, marker+'\n'+include)
p.write_text(s)
PY
nginx -t
systemctl reload nginx
install -d -m 755 /etc/tivano-mirror /var/lib/tivano-mirror
install -m 644 tivano-mirror.logrotate /etc/tivano-mirror/logrotate.conf
install -m 644 tivano-mirror-logrotate.service tivano-mirror-logrotate.timer /etc/systemd/system/
logrotate --debug /etc/tivano-mirror/logrotate.conf
systemctl daemon-reload
systemctl enable --now tivano-mirror-logrotate.timer
systemctl start tivano-mirror-logrotate.service
trap - ERR
printf 'BACKUP=%s\n' "$BACKUP"
printf 'Mirror route active; publish through the restricted account before client use.\n'
