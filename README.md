# Lab 7 — Host Your CV on AWS

Muhammad Arslan · **23L-3025** · iqbalarslan009@gmail.com

This project hosts my CV through an EC2 web server and a Python Lambda Function URL, with a private S3 bucket as the shared source. The portfolio HTML, responsive CSS and original CV PDF are preserved.

| Resource | Address or name |
| --- | --- |
| Repository | https://github.com/m-arslan009/Lab-7-CV-AWS-Hosting |
| EC2 website | http://54.252.152.179 |
| Lambda website | https://mxih5vg6yivpvbekwwnzgiyo7y0vhdqv.lambda-url.ap-southeast-2.on.aws/ |
| Region | `ap-southeast-2` (Sydney) |
| S3 bucket | `cv-23l-3025-82741` |
| EC2 instance Name tag | `cv-ec2-23l-3025` |
| EC2 role | `cv-ec2-role-23l-3025` |
| Lambda function | `cv-func-23l-3025` |
| Lambda role | `cv-lambda-role-23l-3025` |

## Verification status

Public endpoint checks were performed on **24 October 2026**. Both hosts returned HTTP 200 for `/`, `/index.html`, `/style.css` and `/cv.pdf`, with the expected HTML, CSS and PDF content types; Lambda `/anything` returned HTTP 404 with `text/html`. Anonymous direct S3 access returned HTTP 403 with `application/xml`. See `evidence.txt` for the actual collector output.

The live EC2 footer was `Hosted on: EC2 i-0dd412efb83c5229b`, and the live Lambda footer was `Hosted on: Lambda cv-func-23l-3025`. Both downloaded PDFs matched the original local PDF byte for byte, and Lambda returned `Cache-Control: max-age=60`. The EC2 instance ID was observed in served HTML; matching it to the running AWS instance still needs authenticated verification.

Local validation passed Python syntax, all four JSON documents, all three Bash scripts, required files and size limits, embedded/standalone sync-script equality, and the collector's exact 11 headings and incorrect-argument behavior. Mocked Lambda checks passed for HTML/CSS/PDF routing, base64 round-trip, environment variables, unknown/traversal paths, retrieval failures and one JSON record per handled request. HTML/CSS/PDF SHA-256 hashes confirm the original site files are unchanged. Responsive rules were checked in the existing CSS; a browser-based mobile rendering check is still recommended.

**AWS configuration remains unverified:** AWS CLI is not installed in the preparation environment, so `evidence.txt` records real command-not-found errors for AWS queries. The IAM JSON files are **proposed least-privilege policies, not exports of the deployed roles**. The EC2 scripts and Lambda handler are reviewed local source; they have not been installed or deployed by this preparation task. No active AWS resource was changed.

Before final submission, run the collector in an authenticated AWS environment, replace the proposed policies with verified actual exports, and add the two EC2 output excerpts requested below. Successful HTTP responses alone do not prove S3 Block Public Access, versioning, IAM scope, runtime, memory, timeout, log retention, tags or budget settings.

## Architecture

```mermaid
flowchart LR
    Visitor[Public visitor] -->|HTTP port 80| Nginx[EC2 Amazon Linux 2023 / Nginx]
    Visitor -->|HTTPS Function URL| Function[Python Lambda]
    Timer[systemd timer every 4 minutes] --> Sync[EC2 sync script]
    Sync -->|EC2 role: ListBucket site/ and GetObject| Bucket[(Private S3 / site/)]
    Sync -->|Replace footer and publish files| Nginx
    Function -->|Lambda role: GetObject| Bucket
    Function --> Logs[CloudWatch Logs / target retention 7 days]
    Visitor -. Direct S3 GET denied .-> Bucket
```

An EC2 request reaches Nginx on port 80, which serves a local copy refreshed from private S3 using the instance role. A Lambda request reaches the public Function URL, whose handler retrieves the selected S3 object using the function role and builds the HTTP response.

## Repository

```text
README.md
collect-evidence.sh
evidence.txt
site/
  index.html
  style.css
  cv.pdf
ec2/
  user-data.sh
  sync-cv.sh
lambda/
  lambda_function.py
iam/
  ec2-trust.json
  ec2-permissions.json
  lambda-trust.json
  lambda-permissions.json
```

`.gitignore` protects local credentials, private keys and generated packages; `.gitattributes` keeps shell scripts in LF format. The supplied assignment document is retained locally as a reference, outside the submission commit.

Technologies: Amazon S3, EC2, IAM, Lambda Function URLs, CloudWatch Logs, Amazon Linux 2023, Nginx, systemd, AWS CLI, Python/boto3, Bash, HTML/CSS, Git and curl.

## S3 and IAM

The required S3 state is all four Block Public Access settings enabled, versioning enabled, no bucket policy, and no public ACL grants. Exactly three current objects must exist: `site/index.html`, `site/style.css` and `site/cv.pdf`; retain `Hosted on: {{HOSTED_ON}}` in S3. The local HTML is 13,074 bytes and the PDF is 104,015 bytes, below even the decimal limits of 100 KB and 1 MB. Historical versions may exist because versioning is required.

`ec2-trust.json` trusts `ec2.amazonaws.com`; `lambda-trust.json` trusts `lambda.amazonaws.com`. The proposed EC2 inline permissions allow `s3:GetObject` on the three explicit site object ARNs and `s3:ListBucket` on the named bucket only when `s3:prefix` equals `site/`. Lambda has `s3:GetObject` on those same three explicit objects and no `s3:ListBucket`. Explicit object names avoid wildcard resources as required by Section 4 of the assignment; introducing another asset would require a reviewed policy change.

Lambda additionally requires the separate AWS managed policy `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`. That attachment is not part of `lambda-permissions.json`, which is the S3 inline policy. Its presence must be verified with `list-attached-role-policies`; it has not been assumed or applied here. There are no static AWS credentials in the submitted source.

To export actual role documents after authenticating, use the following read-only commands from the repository root. Discover the real inline policy names rather than assuming a name:

```bash
export AWS_DEFAULT_REGION=ap-southeast-2 AWS_PAGER=""
aws iam get-role --role-name cv-ec2-role-23l-3025 \
  --query Role.AssumeRolePolicyDocument --output json > iam/ec2-trust.json
aws iam get-role --role-name cv-lambda-role-23l-3025 \
  --query Role.AssumeRolePolicyDocument --output json > iam/lambda-trust.json
aws iam list-role-policies --role-name cv-ec2-role-23l-3025
aws iam list-role-policies --role-name cv-lambda-role-23l-3025
# Replace the two policy-name arguments with the names returned above.
aws iam get-role-policy --role-name cv-ec2-role-23l-3025 \
  --policy-name ACTUAL_EC2_INLINE_POLICY_NAME --query PolicyDocument --output json > iam/ec2-permissions.json
aws iam get-role-policy --role-name cv-lambda-role-23l-3025 \
  --policy-name ACTUAL_LAMBDA_INLINE_POLICY_NAME --query PolicyDocument --output json > iam/lambda-permissions.json
aws iam list-attached-role-policies --role-name cv-lambda-role-23l-3025
```

Review successful output before committing; a failed command can leave an empty redirected file. If a role has multiple inline policies, export and review all of them rather than representing one as its full permissions. If actual policies differ from the assignment, record the discrepancy and seek approval before changing the deployed role.

## EC2 implementation and setup

`ec2/user-data.sh` is intended for a new Amazon Linux 2023 instance. It checks the operating system, installs Nginx, AWS CLI, Python and locking utilities, embeds the exact standalone sync script in `/opt/cv/sync-cv.sh`, and creates a systemd service and timer. It starts Nginx, enables the timer and starts the initial sync. The existing instance's user data has not been replaced.

The sync script uses temporary credentials supplied by the IAM instance role. It downloads `site/` into a temporary staging directory, retrieves the real instance ID through an IMDSv2 token, validates all three files, and replaces the placeholder with `EC2 <instance-id>`. Each file is published with an atomic rename after downloads succeed; HTML is published last. Staging afresh also prevents a previously substituted footer from defeating later synchronization. The script writes a UTC timestamp and `SUCCESS` or `FAILED` to `/var/log/cv-sync.log` and uses a lock to prevent concurrent runs.

The timer starts the service every four minutes; the service has a 50-second timeout, leaving headroom within the five-minute update requirement during successful operation. Network or permission failures can delay updates and are recorded as failures; the next timer run retries. Nginx's standard MIME configuration serves HTML, CSS and PDF.

For a reviewed future deployment, use one eligible `t2.micro` or `t3.micro` Amazon Linux 2023 instance, attach the instance profile containing the EC2 role, require IMDSv2 (`HttpTokens=required`), and use its ordinary public IPv4 address. Permit inbound TCP 80 from anywhere; TCP 22 must be absent or restricted to your own single `/32`; allow no other inbound rules. Do not allocate an Elastic IP, NAT gateway or load balancer. Use `Owner=23l-3025` and `Course=cloud` tags on the instance, bucket, function and both roles. Check your account's actual Free Tier/credits and budget in Billing.

Read-only checks from a shell on the existing instance:

```bash
cat /etc/os-release
systemctl status nginx cv-sync.timer --no-pager
systemctl cat cv-sync.service cv-sync.timer
sudo tail -n 10 /var/log/cv-sync.log
```

## Lambda implementation and setup

Handler: `lambda_function.lambda_handler`. `BUCKET` and `PREFIX` are required environment variables; configure them as `cv-23l-3025-82741` and `site/`. The handler does not hard-code the bucket or prefix. Use the latest Python runtime offered for this Region, 128–256 MB memory, a 10-second timeout, and seven-day retention on `/aws/lambda/cv-func-23l-3025`; the actual values require AWS verification.

`/` and `/index.html` return HTML with the footer `Hosted on: Lambda cv-func-23l-3025` and `Cache-Control: max-age=60`. `/style.css` returns CSS; `/cv.pdf` returns a base64 body with `isBase64Encoded=true` and `Content-Type: application/pdf`. Unknown paths return a short HTML page with status 404 without accessing S3. Internal retrieval failures return a generic error; known missing objects return 404, but S3 can conceal a missing object as AccessDenied when the role lacks ListBucket. Each handled request prints one JSON record with `fn`, `path`, `status` and elapsed `ms`; Lambda platform lifecycle logs are separate.

Use Function URL authentication `NONE` and verify the function resource policy grants public URL invocation. Current AWS guidance requires both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`, with conditions restricting this permission to the Function URL. These invocation permissions are distinct from the execution role's private S3 access. No function code, environment, URL policy or log group was modified here.

For a future approved code deployment, package `lambda/lambda_function.py` at the root of the ZIP, choose the handler above, review the current configuration, and deploy through your existing Lambda function. Preserve the known working deployment until its configuration and source have been exported and compared. Likewise, review S3 changes before uploading: the EC2 timer automatically publishes them.

## Testing and evidence collection

Run this from a Bash shell with AWS CLI and curl available, preferably AWS CloudShell in Sydney or an approved authenticated CLI session. Use temporary/session credentials with the required read permissions; never put credentials in this repository.

```bash
bash collect-evidence.sh cv-23l-3025-82741 \
  http://54.252.152.179 \
  https://mxih5vg6yivpvbekwwnzgiyo7y0vhdqv.lambda-url.ap-southeast-2.on.aws/
```

The collector writes `evidence.txt`, records command failures, continues through exactly 11 named sections, and prints `DONE`. It checks public status/content types and direct S3 access even when AWS queries fail. With two arguments it prints usage and exits 1. Re-run it in your AWS environment and commit the resulting genuine output, replacing this preparation run with its missing-CLI errors. The script is specific to this lab's named roles, function and instance; its three arguments select the bucket and public addresses. Additional C15 read-only checks inspect instance counts, IP allocations, NAT gateways, load balancers and budget existence in the configured Region.

Useful local validation commands:

```bash
python -c "import ast,pathlib; ast.parse(pathlib.Path('lambda/lambda_function.py').read_text())"
bash -n collect-evidence.sh
bash -n ec2/user-data.sh
bash -n ec2/sync-cv.sh
python -m json.tool iam/ec2-trust.json > /dev/null
python -m json.tool iam/ec2-permissions.json > /dev/null
python -m json.tool iam/lambda-trust.json > /dev/null
python -m json.tool iam/lambda-permissions.json > /dev/null
```

### Required EC2 access-denied excerpt

**Pending: no instance shell or authenticated AWS access was available.** The assignment requires a real failed overwrite/delete attempt using the instance role. Do not substitute anonymous S3 HTTP 403 for that proof; it tests different permissions. Verify the role denies writes before performing the instructor's test, and paste the actual failed command and AccessDenied output here. No write/delete attempt was made during preparation.

### Required final ten EC2 synchronization log entries

**Pending: retrieve the actual entries with `sudo tail -n 10 /var/log/cv-sync.log` on the instance and paste them here.** Confirm at least three consecutive scheduled runs. No sample log lines are presented as evidence.

## Section 8 written answers

### 1. Why roles instead of access keys, and what if keys were in user data?

Roles supply temporary credentials that AWS rotates, with permissions scoped to the workload. Long-lived keys in user data could be exposed through instance configuration, copied scripts or logs. Anyone obtaining them could use their permissions until they were revoked, potentially outside the intended instance or function.

### 2. What happens when someone opens the direct S3 address?

The anonymous browser request receives HTTP 403 AccessDenied, which was observed in the public endpoint check. The intended configuration keeps all four Block Public Access settings enabled and grants no public bucket-policy or ACL access. Private role grants let the two workloads read the objects without making them public. HTTP 403 alone does not prove that every required bucket setting is configured correctly.

### 3. Why is public Function URL permission acceptable?

With authentication `NONE`, the function resource policy permits anonymous URL invocation using the required invocation actions, restricted to that function and URL context. The execution role separately limits which S3 objects the function can read. Public invocation is appropriate because the handler intentionally publishes only the CV routes. Public bucket access would bypass that routing and response logic and violate the private-source requirement.

### 4. What costs remain at idle, and what happens with 100 times the traffic?

A running EC2 instance has compute costs even without visitors, with storage and public IPv4 charges also potentially applying after credits or allowances. On-demand Lambda normally has no request/compute charges when it is not invoked, although S3 storage, stored logs and other applicable services still cost money. At 100 times the traffic, the single EC2 instance may become a bottleneck, while Lambda scales subject to concurrency, throttling and downstream limits. Lambda request/duration, S3 reads and transfer charges can increase with traffic, so the actual account budget and pricing must be checked.

### 5. What remains if the EC2 instance is deleted?

The instance's running web server, local sync state and ordinary public IPv4 endpoint are lost; attached volumes are deleted or retained according to their deletion settings. S3 objects and versions, the Lambda hosting path, repository and separate IAM roles remain unless explicitly deleted. Any retained volumes or other resources may continue to incur charges. The EC2 path can be rebuilt from the retained source and configuration after approval.

## Submission checklist

- Refresh `evidence.txt` using AWS CLI and replace the proposed IAM JSON with verified deployed policies; confirm all C7–C10 and C13 requirements.
- Paste the actual instance-role AccessDenied output and last ten sync log lines above.
- Verify runtime, 128–256 MB memory, 10-second timeout, seven-day retention, tags on all five required resources, account budget and C15 resource hygiene.
- Check both public sites, footers, PDF rendering and mobile layout immediately before submission; keep both endpoints working until marking ends.
- Review staged content for secrets/private keys, then commit and push to `main` with an account authorized to write this existing repository.
- Submit the repository URL, both website URLs and roll number `23L-3025` through the instructor's channel.

## References and authorship

The existing portfolio and CV were retained. Repository preparation, the proposed Lambda handler, revised synchronization code, proposed policies and evidence collector were prepared with Codex assistance; review them and be able to explain them before submission, and confirm the instructor's AI-tool policy (the provided assignment leaves it unspecified).

Adapted using official AWS documentation: [Function URL request/response format](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html), [Function URL access control](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html), [S3 IAM resource and action scoping](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security_iam_service-with-iam.html), and [Lambda runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html). Cost discussion follows [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/) and [Lambda pricing](https://aws.amazon.com/lambda/pricing/); no fixed prices or Free Tier eligibility are assumed for this account.
