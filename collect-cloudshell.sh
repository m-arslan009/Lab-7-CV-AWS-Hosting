#!/bin/bash
# Authenticated read-only AWS collection plus local IAM exports. No deployment.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export AWS_REGION=ap-southeast-2 AWS_DEFAULT_REGION=ap-southeast-2 AWS_PAGER=""
for tool in aws curl python3; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool is required. Use AWS CloudShell." >&2; exit 127; }
done
aws --version
# A failed login stops before touching any existing evidence or policy file.
aws sts get-caller-identity
mkdir -p .validation/backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
[[ ! -f evidence.txt ]] || cp evidence.txt ".validation/backups/evidence-$stamp.txt"
bash ./collect-evidence.sh cv-23l-3025-82741 \
    http://54.252.152.179 \
    https://mxih5vg6yivpvbekwwnzgiyo7y0vhdqv.lambda-url.ap-southeast-2.on.aws/
python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

def aws(*args):
    # Do not query credentials or complete Lambda environment variables.
    return json.loads(subprocess.check_output(['aws', *args, '--output', 'json'], text=True))

try:
    caller = aws('sts', 'get-caller-identity')
    documents = {}
    metadata = {'collectedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'caller': caller, 'roles': {}, 'reviewFindings': []}
    bucket = 'cv-23l-3025-82741'
    expected_objects = {f'arn:aws:s3:::{bucket}/site/{name}' for name in ('index.html','style.css','cv.pdf')}
    for kind, role in [('ec2', 'cv-ec2-role-23l-3025'), ('lambda', 'cv-lambda-role-23l-3025')]:
        info = aws('iam', 'get-role', '--role-name', role)['Role']
        names = aws('iam', 'list-role-policies', '--role-name', role)['PolicyNames']
        attached = aws('iam', 'list-attached-role-policies', '--role-name', role)['AttachedPolicies']
        policies = {name: aws('iam', 'get-role-policy', '--role-name', role, '--policy-name', name)['PolicyDocument'] for name in names}
        metadata['roles'][role] = {'arn': info['Arn'], 'tags': info.get('Tags', []), 'attachedPolicies': attached, 'inlinePolicies': policies}
        # Avoid collapsing several real policies into a made-up combined policy.
        if len(names) != 1:
            raise RuntimeError(f'{role} has {len(names)} inline policies; expected one. No four-file replacement performed; inspect evidence.txt.')
        documents[f'{kind}-trust.json'] = info['AssumeRolePolicyDocument']
        documents[f'{kind}-permissions.json'] = policies[names[0]]
        statements = policies[names[0]].get('Statement', [])
        if isinstance(statements, dict):
            statements = [statements]
        actions = set()
        for statement in statements:
            action = statement.get('Action', [])
            resource = statement.get('Resource', [])
            action = [action] if isinstance(action, str) else action
            resource = [resource] if isinstance(resource, str) else resource
            actions.update(action)
            if any('*' in value or '?' in value for value in action + resource):
                metadata['reviewFindings'].append(f'{role}: wildcard in inline action/resource')
            if statement.get('Effect') != 'Allow' or 'NotAction' in statement or 'NotResource' in statement:
                metadata['reviewFindings'].append(f'{role}: review nonstandard statement')
            if 's3:GetObject' in action and set(resource) != expected_objects:
                metadata['reviewFindings'].append(f'{role}: GetObject resources differ from the three required object ARNs')
            if 's3:ListBucket' in action:
                condition = statement.get('Condition', {})
                if set(resource) != {f'arn:aws:s3:::{bucket}'} or condition != {'StringEquals': {'s3:prefix': 'site/'}}:
                    metadata['reviewFindings'].append(f'{role}: review ListBucket scope and prefix condition')
        expected_actions = {'s3:GetObject', 's3:ListBucket'} if kind == 'ec2' else {'s3:GetObject'}
        if actions != expected_actions:
            metadata['reviewFindings'].append(f'{role}: inline actions differ from assignment')
        expected_attached = set() if kind == 'ec2' else {'arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'}
        if {p['PolicyArn'] for p in attached} != expected_attached:
            metadata['reviewFindings'].append(f'{role}: managed-policy attachments differ from assignment')
        trust = info['AssumeRolePolicyDocument'].get('Statement', [])
        if isinstance(trust, dict):
            trust = [trust]
        if len(trust) != 1 or trust[0].get('Principal') != {'Service': f'{kind}.amazonaws.com'} or trust[0].get('Action') != 'sts:AssumeRole' or trust[0].get('Effect') != 'Allow':
            metadata['reviewFindings'].append(f'{role}: review service trust policy')
    # Fetch everything before replacing any local draft. Preserve old files locally.
    directory = Path('iam')
    directory.mkdir(exist_ok=True)
    backup = Path('.validation/backups') / datetime.datetime.now(datetime.timezone.utc).strftime('iam-%Y%m%dT%H%M%S%fZ')
    backup.mkdir()
    documents['deployed-policy-metadata.json'] = metadata
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        for name, document in documents.items():
            text = json.dumps(document, indent=2) + '\n'
            json.loads(text)
            Path(temporary, name).write_text(text, encoding='utf-8')
        for name in documents:
            destination = directory / name
            if destination.exists():
                (backup / name).write_bytes(destination.read_bytes())
            os.replace(Path(temporary, name), destination)
    print('Actual IAM policies exported. Source and managed attachments: iam/deployed-policy-metadata.json')
    for finding in metadata['reviewFindings']:
        print('REVIEW:', finding)
    print('Exports are actual AWS state; review findings do not change deployed permissions.')
except (subprocess.CalledProcessError, ValueError, RuntimeError) as exc:
    raise SystemExit(f'ERROR: IAM export incomplete: {exc}. Existing four policy files were retained if retrieval failed.')
PY
echo 'Review evidence.txt and IAM exports. EC2 logs and role-denial proof still require an instance shell.'
echo 'No AWS configuration was changed. Review the files before committing.'
