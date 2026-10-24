#!/bin/bash
# Read-only AWS/HTTP collection. No AWS resources are modified.
set -uo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <s3-bucket> <ec2-url> <lambda-url>" >&2
    exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
    cat >&2 <<'HELP'
ERROR: AWS CLI is unavailable. No new AWS evidence was collected.
Existing evidence.txt was preserved.
Open AWS CloudShell in ap-southeast-2, then run:
  git clone https://github.com/m-arslan009/Lab-7-CV-AWS-Hosting.git
  cd Lab-7-CV-AWS-Hosting
  bash collect-cloudshell.sh
CloudShell supplies AWS CLI and your signed-in session; do not paste credentials.
HELP
    exit 127
fi
if ! command -v curl >/dev/null 2>&1; then
    echo 'ERROR: curl is required; existing evidence.txt was preserved.' >&2
    exit 127
fi
BUCKET=$1
EC2_URL=${2%/}
LAMBDA_URL=${3%/}
URL_REGION=""
if [[ "$LAMBDA_URL" =~ \.lambda-url\.([a-z0-9-]+)\.on\.aws ]]; then
    URL_REGION=${BASH_REMATCH[1]}
fi
CONFIG_REGION=$(aws configure get region 2>/dev/null || true)
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-${URL_REGION:-${CONFIG_REGION:-ap-southeast-2}}}}
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
export AWS_MAX_ATTEMPTS=2 AWS_RETRY_MODE=standard
EC2_ROLE=cv-ec2-role-23l-3025
LAMBDA_ROLE=cv-lambda-role-23l-3025
FUNCTION=cv-func-23l-3025
INSTANCE_NAME=cv-ec2-23l-3025
LOG_GROUP="/aws/lambda/$FUNCTION"
ACCOUNT="" INSTANCE_ID="" FUNCTION_ARN="" ERRORS=0
LAST_OUTPUT="" LAST_RC=0
section() { printf '\n== %s ==\n' "$1"; }
error() { printf 'ERROR: %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
run_expected() {
    local expected=$1
    shift
    printf '\n$'; printf ' %q' "$@"; printf '\n'
    LAST_OUTPUT=$("$@" 2>&1); LAST_RC=$?
    printf '%s\n' "$LAST_OUTPUT"
    if (( LAST_RC != 0 )); then
        if [[ -n "$expected" && "$LAST_OUTPUT" == *"($expected)"* ]]; then
            printf 'EXPECTED: %s; command exit status %s\n' "$expected" "$LAST_RC"
        else
            error "command exited with status $LAST_RC"
        fi
    fi
    return 0
}
run() { run_expected '' "$@"; }
role_policies() {
    local role=$1 names arn version name
    run aws iam get-role --role-name "$role"
    run aws iam list-role-policies --role-name "$role" --query PolicyNames --output text
    if (( LAST_RC == 0 )); then
        names=$LAST_OUTPUT
        for name in $names; do
            [[ "$name" == None ]] && continue
            run aws iam get-role-policy --role-name "$role" --policy-name "$name"
        done
    fi
    run aws iam list-attached-role-policies --role-name "$role"
    run aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text
    if (( LAST_RC == 0 )); then
        names=$LAST_OUTPUT
        for arn in $names; do
            [[ "$arn" == None ]] && continue
            run aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text
            if (( LAST_RC == 0 )); then
                version=$LAST_OUTPUT
                run aws iam get-policy-version --policy-arn "$arn" --version-id "$version"
            fi
        done
    fi
}
{
    section caller
    printf 'Collected at %s; initial Region %s\n' "$(date -u +%FT%TZ)" "$REGION"
    run aws --version
    run aws sts get-caller-identity
    run aws sts get-caller-identity --query Account --output text
    if (( LAST_RC == 0 )) && [[ "$LAST_OUTPUT" =~ ^[0-9]{12}$ ]]; then
        ACCOUNT=$LAST_OUTPUT
    else
        error 'Account ID unavailable; account-dependent checks will be skipped.'
    fi
    run aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text
    if (( LAST_RC == 0 )); then
        case "$LAST_OUTPUT" in None|null) REGION=us-east-1;; EU) REGION=eu-west-1;; *) REGION=$LAST_OUTPUT;; esac
        export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
        printf 'Discovered bucket Region: %s\n' "$REGION"
        if [[ -n "$URL_REGION" && "$URL_REGION" != "$REGION" ]]; then
            error "Lambda URL Region $URL_REGION differs from bucket Region $REGION; lab requires one Region."
        fi
    else
        printf 'Bucket Region unverified; retaining configured/URL Region %s\n' "$REGION"
    fi
    section public-access
    run aws s3api get-public-access-block --bucket "$BUCKET"
    run_expected NoSuchBucketPolicy aws s3api get-bucket-policy --bucket "$BUCKET"
    run aws s3api get-bucket-acl --bucket "$BUCKET"
    run aws s3api get-bucket-ownership-controls --bucket "$BUCKET"
    run aws s3api get-bucket-tagging --bucket "$BUCKET"
    section versioning
    run aws s3api get-bucket-versioning --bucket "$BUCKET"
    section objects
    run aws s3 ls "s3://$BUCKET/site/" --recursive
    run aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].{Key:Key,Size:Size}'
    section ec2-policy
    # Discover the unique running instance and the role actually in its profile.
    run aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].InstanceId' --output text
    if (( LAST_RC == 0 )); then
        read -r -a ids <<< "${LAST_OUTPUT//$'\n'/ }"
        if [[ ${#ids[@]} == 1 && "${ids[0]}" =~ ^i-[0-9a-f]+$ ]]; then
            INSTANCE_ID=${ids[0]}
        else
            error 'Expected exactly one running named instance; instance-specific discovery skipped.'
        fi
    fi
    if [[ -n "$INSTANCE_ID" ]]; then
        run aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
        if (( LAST_RC == 0 )) && [[ "$LAST_OUTPUT" == arn:*:instance-profile/* ]]; then
            PROFILE=${LAST_OUTPUT##*/}
            run aws iam get-instance-profile --instance-profile-name "$PROFILE"
            run aws iam get-instance-profile --instance-profile-name "$PROFILE" --query 'InstanceProfile.Roles[0].RoleName' --output text
            if (( LAST_RC == 0 )) && [[ -n "$LAST_OUTPUT" && "$LAST_OUTPUT" != None ]]; then
                [[ "$LAST_OUTPUT" == "$EC2_ROLE" ]] || error "Attached EC2 role differs from required $EC2_ROLE"
                EC2_ROLE=$LAST_OUTPUT
            fi
        else
            error 'No readable instance profile ARN; inspecting the expected role only.'
        fi
    fi
    role_policies "$EC2_ROLE"
    section lambda-policy
    run aws lambda get-function-configuration --function-name "$FUNCTION" --query Role --output text
    if (( LAST_RC == 0 )) && [[ "$LAST_OUTPUT" == arn:*:role/* ]]; then
        ACTUAL_ROLE=${LAST_OUTPUT##*/}
        [[ "$ACTUAL_ROLE" == "$LAMBDA_ROLE" ]] || error "Attached Lambda role differs from required $LAMBDA_ROLE"
        LAMBDA_ROLE=$ACTUAL_ROLE
    fi
    role_policies "$LAMBDA_ROLE"
    section security-group
    if [[ -n "$INSTANCE_ID" ]]; then
        run aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text
        if (( LAST_RC == 0 )) && [[ -n "$LAST_OUTPUT" && "$LAST_OUTPUT" != None ]]; then
            read -r -a groups <<< "${LAST_OUTPUT//$'\n'/ }"
            run aws ec2 describe-security-groups --group-ids "${groups[@]}"
        else
            error 'No readable instance security groups.'
        fi
    else
        error 'No unique instance ID; security-group query skipped.'
    fi
    section instance
    run aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
        --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Image:ImageId,PublicIP:PublicIpAddress,Metadata:MetadataOptions,Profile:IamInstanceProfile,Tags:Tags}'
    if [[ -n "$INSTANCE_ID" ]]; then
        run aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].ImageId' --output text
        if (( LAST_RC == 0 )) && [[ "$LAST_OUTPUT" == ami-* ]]; then
            IMAGE=$LAST_OUTPUT
            run aws ec2 describe-images --image-ids "$IMAGE"
        fi
    fi
    run aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Tags:Tags}'
    run aws ec2 describe-addresses
    run aws ec2 describe-nat-gateways --filter 'Name=state,Values=pending,available'
    run aws elbv2 describe-load-balancers
    run aws elb describe-load-balancers
    if [[ -n "$ACCOUNT" ]]; then
        run aws budgets describe-budgets --account-id "$ACCOUNT" --query 'Budgets[].{Name:BudgetName,Type:BudgetType,Limit:BudgetLimit}'
    else
        echo 'SKIPPED: budget query requires a discovered account ID.'
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
        "https://$BUCKET.s3.$REGION.amazonaws.com/site/index.html"
    section lambda-logs
    run aws logs tail "$LOG_GROUP" --since 1h --format short
    section log-retention
    run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
        --query "logGroups[?logGroupName=='$LOG_GROUP'].{Name:logGroupName,RetentionDays:retentionInDays}"
    run aws lambda get-function-configuration --function-name "$FUNCTION" \
        --query '{Name:FunctionName,Arn:FunctionArn,Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,Role:Role,BUCKET:Environment.Variables.BUCKET,PREFIX:Environment.Variables.PREFIX,Logging:LoggingConfig}'
    run aws lambda get-function-configuration --function-name "$FUNCTION" --query FunctionArn --output text
    if (( LAST_RC == 0 )) && [[ "$LAST_OUTPUT" == arn:*:lambda:*:function:* ]]; then
        FUNCTION_ARN=$LAST_OUTPUT
        run aws lambda list-tags --resource "$FUNCTION_ARN"
    else
        echo 'SKIPPED: Lambda tags require the actual function ARN.'
    fi
    run aws lambda get-function-url-config --function-name "$FUNCTION"
    run aws lambda get-policy --function-name "$FUNCTION"
    printf '\nCollection finished with %s unexpected command/discovery error(s). Review configuration values separately.\n' "$ERRORS"
} > evidence.txt 2>&1
WRITE_RC=$?
if (( WRITE_RC != 0 )); then
    echo 'ERROR: could not write evidence.txt' >&2
    exit "$WRITE_RC"
fi
printf '%s unexpected errors; inspect evidence.txt.\n' "$ERRORS" >&2
echo DONE
