#!/bin/bash
# Run ON the existing EC2 instance, or stream through SSH. No real CV key is targeted.
set -uo pipefail
export AWS_REGION=ap-southeast-2 AWS_DEFAULT_REGION=ap-southeast-2 AWS_PAGER=""
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_EC2_METADATA_DISABLED=false
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE \
    AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE \
    AWS_EC2_METADATA_SERVICE_ENDPOINT AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE || true
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@" 2>&1; rc=$?; ((rc == 0)) || echo "ERROR: exit $rc"; return 0; }
echo '== instance-identity =='
run date -u +%FT%TZ
run cat /etc/os-release
TOKEN=$(curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS -X PUT \
    http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') || exit 1
echo '$ curl IMDSv2 instance-id (metadata token omitted)'
curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS \
    -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id || exit 1
# Do not print the temporary metadata token or retrieve role credential JSON.
echo
run aws sts get-caller-identity
ROLE_IDENTITY=$(aws sts get-caller-identity --query Arn --output text) || exit 1
if [[ "$ROLE_IDENTITY" != arn:*:sts::*:assumed-role/cv-ec2-role-23l-3025/* ]]; then
    echo 'ERROR: caller is not the expected EC2 role; no deletion probe will run.' >&2
    exit 1
fi
echo '== synchronization-timer =='
run systemctl list-timers --all --no-pager
run systemctl cat cv-sync.service cv-sync.timer
run systemctl status cv-sync.timer --no-pager
echo '== sync-log =='
run sudo -n tail -n 10 /var/log/cv-sync.log
echo '== instance-role-delete-denial =='
# A random nonexistent key and explicit null version cannot delete the CV files
# or create a versioning delete marker, even if deletion is unexpectedly allowed.
NONCE=$(cat /proc/sys/kernel/random/uuid) || exit 1
KEY="site/.readonly-probe-$NONCE"
printf '$ aws s3api delete-object --bucket cv-23l-3025-82741 --key %q --version-id null\n' "$KEY"
OUTPUT=$(aws s3api delete-object --bucket cv-23l-3025-82741 --key "$KEY" --version-id null 2>&1)
RC=$?
printf '%s\nExit status: %s\n' "$OUTPUT" "$RC"
if (( RC != 0 )) && [[ "$OUTPUT" == *AccessDenied* ]]; then
    echo 'Verified: the instance-role deletion probe returned AccessDenied.'
else
    echo 'UNVERIFIED: expected AccessDenied was not observed. Review IAM; do not test a real CV object.'
fi
