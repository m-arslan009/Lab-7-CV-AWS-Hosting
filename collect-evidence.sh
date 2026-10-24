#!/bin/bash
# Read-only collection. Run from an authenticated AWS CLI shell/CloudShell.
set -uo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <s3-bucket> <ec2-url> <lambda-url>" >&2
    exit 1
fi
BUCKET=$1
EC2_URL=${2%/}
LAMBDA_URL=${3%/}
export AWS_DEFAULT_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}
export AWS_PAGER=""
export AWS_MAX_ATTEMPTS=2
export AWS_RETRY_MODE=standard
EC2_ROLE=cv-ec2-role-23l-3025
LAMBDA_ROLE=cv-lambda-role-23l-3025
FUNCTION=cv-func-23l-3025
LOG_GROUP="/aws/lambda/$FUNCTION"
INSTANCE_NAME=cv-ec2-23l-3025
section() { printf '\n== %s ==\n' "$1"; }
run() {
    printf '\n$'; printf ' %q' "$@"; printf '\n'
    "$@" 2>&1
    rc=$?
    if (( rc != 0 )); then printf 'ERROR: command exited with status %s\n' "$rc"; fi
    return 0
}
capture() {
    local result rc
    result=$("$@" 2>&1); rc=$?
    if (( rc != 0 )); then
        printf 'ERROR: discovery failed (%s): %s\n' "$rc" "$result" >&2
        return 1
    fi
    printf '%s' "$result"
}
role_policies() {
    local role=$1 names arn version
    run aws iam get-role --role-name "$role"
    run aws iam list-role-policies --role-name "$role"
    run aws iam list-attached-role-policies --role-name "$role"
    if names=$(capture aws iam list-role-policies --role-name "$role" --query PolicyNames --output text); then
        for name in $names; do
            run aws iam get-role-policy --role-name "$role" --policy-name "$name"
        done
    fi
    if names=$(capture aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); then
        for arn in $names; do
            run aws iam get-policy --policy-arn "$arn"
            if version=$(capture aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text); then
                run aws iam get-policy-version --policy-arn "$arn" --version-id "$version"
            fi
        done
    fi
}
{
    section caller
    printf 'Collected at %s; Region %s\n' "$(date -u +%FT%TZ)" "$AWS_DEFAULT_REGION"
    run aws sts get-caller-identity
    section public-access
    run aws s3api get-public-access-block --bucket "$BUCKET"
    run aws s3api get-bucket-policy --bucket "$BUCKET"
    run aws s3api get-bucket-acl --bucket "$BUCKET"
    run aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
    run aws s3api get-bucket-tagging --bucket "$BUCKET"
    section versioning
    run aws s3api get-bucket-versioning --bucket "$BUCKET"
    section objects
    run aws s3 ls "s3://$BUCKET/site/" --recursive
    # Also expose unexpected objects outside site/.
    run aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].{Key:Key,Size:Size}'
    section ec2-policy
    role_policies "$EC2_ROLE"
    section lambda-policy
    role_policies "$LAMBDA_ROLE"
    section security-group
    if groups=$(capture aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text); then
        if [[ -n "$groups" && "$groups" != None ]]; then
            read -r -a group_ids <<< "${groups//$'\n'/ }"
            run aws ec2 describe-security-groups --group-ids "${group_ids[@]}"
        else
            echo 'ERROR: no running matching instance/security groups found'
        fi
    fi
    section instance
    run aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
        --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Image:ImageId,PublicIP:PublicIpAddress,Metadata:MetadataOptions,Profile:IamInstanceProfile,Tags:Tags}'
    if images=$(capture aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query 'Reservations[].Instances[].ImageId' --output text); then
        for image in $images; do run aws ec2 describe-images --image-ids "$image"; done
    fi
    if profiles=$(capture aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text); then
        for profile in $profiles; do
            run aws iam get-instance-profile --instance-profile-name "${profile##*/}"
        done
    fi
    # Cost/hygiene checks required by C15; no resources are changed.
    run aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Tags:Tags}'
    run aws ec2 describe-addresses
    run aws ec2 describe-nat-gateways --filter 'Name=state,Values=pending,available'
    run aws elbv2 describe-load-balancers
    run aws elb describe-load-balancers
    if account=$(capture aws sts get-caller-identity --query Account --output text); then
        run aws budgets describe-budgets --account-id "$account" --query 'Budgets[].{Name:BudgetName,Type:BudgetType,Limit:BudgetLimit}'
    fi
    section endpoints
    for base in "$EC2_URL" "$LAMBDA_URL"; do
        for path in / /index.html /style.css /cv.pdf; do
            run curl --connect-timeout 5 --max-time 20 --silent --show-error --output /dev/null \
                --write-out 'URL=%{url_effective} status=%{http_code} content-type=%{content_type}\n' "$base$path"
        done
    done
    run curl --connect-timeout 5 --max-time 20 --silent --show-error --output /dev/null \
        --write-out 'URL=%{url_effective} status=%{http_code} content-type=%{content_type}\n' "$LAMBDA_URL/anything"
    run curl --connect-timeout 5 --max-time 20 --silent --show-error --output /dev/null \
        --write-out 'Direct S3: status=%{http_code} content-type=%{content_type}\n' \
        "https://$BUCKET.s3.$AWS_DEFAULT_REGION.amazonaws.com/site/index.html"
    section lambda-logs
    run aws logs tail "$LOG_GROUP" --since 1h --format short
    section log-retention
    run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
        --query "logGroups[?logGroupName=='$LOG_GROUP'].{Name:logGroupName,RetentionDays:retentionInDays}"
    run aws lambda get-function-configuration --function-name "$FUNCTION" \
        --query '{Name:FunctionName,Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,Role:Role,BUCKET:Environment.Variables.BUCKET,PREFIX:Environment.Variables.PREFIX,Logging:LoggingConfig}'
    run aws lambda list-tags --resource "arn:aws:lambda:$AWS_DEFAULT_REGION:${account:-unknown}:function:$FUNCTION"
    run aws lambda get-function-url-config --function-name "$FUNCTION"
    run aws lambda get-policy --function-name "$FUNCTION"
} > evidence.txt 2>&1
echo DONE
