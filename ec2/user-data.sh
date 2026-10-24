#!/bin/bash
# For a NEW Amazon Linux 2023 instance only; review before deploying.
set -euo pipefail
. /etc/os-release
[[ "$ID" == amzn && "$VERSION_ID" == 2023 ]] || { echo 'Amazon Linux 2023 required' >&2; exit 1; }
dnf install -y nginx awscli-2 python3 util-linux
install -d -m 755 /opt/cv /var/log
cat > /opt/cv/sync-cv.sh <<'SYNC'
#!/bin/bash
# Proposed local revision; does not change an existing instance until installed.
set -euo pipefail
export AWS_DEFAULT_REGION=ap-southeast-2
export AWS_PAGER=""
export AWS_METADATA_SERVICE_TIMEOUT=3
export AWS_METADATA_SERVICE_NUM_ATTEMPTS=2
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE || true
BUCKET="cv-23l-3025-82741"
WEBROOT="/usr/share/nginx/html"
LOG="/var/log/cv-sync.log"
STAGE=""
finish() {
    result=$?
    trap - EXIT
    if [[ -n "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
    if (( result == 0 )); then state=SUCCESS; else state=FAILED; fi
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$state" >> "$LOG"
    exit "$result"
}
trap finish EXIT
trap 'exit 1' TERM INT
exec 9>/run/cv-sync.lock
flock -w 5 9
STAGE=$(mktemp -d /var/tmp/cv-sync.XXXXXXXX)
# AWS CLI obtains temporary credentials from the instance role through IMDSv2.
aws --cli-connect-timeout 5 --cli-read-timeout 20 s3 sync \
    "s3://${BUCKET}/site/" "$STAGE/" --only-show-errors
TOKEN=$(curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS -X PUT \
    http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
INSTANCE_ID=$(curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
[[ "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]]
INSTANCE_ID="$INSTANCE_ID" STAGE="$STAGE" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["STAGE"])
for name in ("index.html", "style.css", "cv.pdf"):
    if not (root / name).is_file():
        raise RuntimeError("Missing required site object: " + name)
page = root / "index.html"
content = page.read_text(encoding="utf-8")
if "{{HOSTED_ON}}" not in content:
    raise RuntimeError("S3 HTML must retain the hosting placeholder")
page.write_text(content.replace("{{HOSTED_ON}}", "EC2 " + os.environ["INSTANCE_ID"]), encoding="utf-8")
PY
# Stage every run so S3 timestamps never leave a stale, already-replaced footer.
# Each file is atomically renamed; a failed download leaves the served copy intact.
for name in style.css cv.pdf index.html; do
    install -m 644 "$STAGE/$name" "$WEBROOT/.$name.next"
    mv -f "$WEBROOT/.$name.next" "$WEBROOT/$name"
done
SYNC
chmod 755 /opt/cv/sync-cv.sh
cat > /etc/systemd/system/cv-sync.service <<'SERVICE'
[Unit]
Description=Synchronize CV website from private S3
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/cv/sync-cv.sh
TimeoutStartSec=50
SERVICE
cat > /etc/systemd/system/cv-sync.timer <<'TIMER'
[Unit]
Description=Refresh CV website every four minutes
[Timer]
OnBootSec=30s
OnUnitActiveSec=4min
AccuracySec=1s
RandomizedDelaySec=0
Unit=cv-sync.service
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now nginx
# Enable the timer first so transient initial failures can recover automatically.
systemctl enable --now cv-sync.timer
systemctl start cv-sync.service
