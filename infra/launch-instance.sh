#!/usr/bin/env bash
# Launches the coder-agent-poc EC2 instance end to end: resolves the AMI,
# creates the security group if it doesn't exist, runs the instance, and
# waits for it to register with SSM. Reachable only via SSM Session Manager
# — no key pair, no open ports, matching the README's "no inbound rules".
#
# Prerequisites (one-time, not handled here):
#   - poc-coder-agent IAM role + instance profile with the Bedrock/SSM
#     inline policy (infra/instance-role-policy.json) and the AWS-managed
#     AmazonSSMManagedInstanceCore policy both attached.
#   - infra/ec2-userdata.sh edited with your repo URL, model id, GitHub org.
#   - AWS SSO/credentials for the target account already active in this shell
#     (e.g. `export AWS_PROFILE=personal`).
#
# Usage:
#   ./launch-instance.sh
#
# Optional env:
#   AWS_REGION            default: us-east-1
#   INSTANCE_TYPE         default: t3.xlarge
#   VOLUME_SIZE_GB        default: 60
#   INSTANCE_PROFILE      default: poc-coder-agent
#   SG_NAME               default: poc-coder-agent

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.xlarge}"
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-60}"
INSTANCE_PROFILE="${INSTANCE_PROFILE:-poc-coder-agent}"
SG_NAME="${SG_NAME:-poc-coder-agent}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERDATA_FILE="$SCRIPT_DIR/ec2-userdata.sh"

log() { printf '\n=== %s ===\n' "$*"; }

: "${AWS_REGION:?}"
[ -f "$USERDATA_FILE" ] || { echo "missing $USERDATA_FILE"; exit 1; }

if grep -q "YOUR_USER\|YOUR_GITHUB_USER\|PASTE_ID_FROM_README" "$USERDATA_FILE"; then
  echo "ec2-userdata.sh still has placeholder values — edit POC_REPO_URL," \
       "BEDROCK_MODEL_ID and GITHUB_ORG before launching." >&2
  exit 1
fi

log "resolving latest Amazon Linux 2023 AMI"
AMI_ID=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
echo "AMI: $AMI_ID"

log "resolving default VPC"
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "no default VPC — pass one explicitly"; exit 1; }
echo "VPC: $VPC_ID"

log "security group"
SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" --description "coder agent poc — no inbound" \
    --vpc-id "$VPC_ID" --query GroupId --output text)
  echo "created $SG_ID (no ingress rules — reachable only via SSM)"
else
  echo "reusing $SG_ID"
fi

log "launching instance"
INSTANCE_ID=$(aws ec2 run-instances --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "file://$USERDATA_FILE" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=poc-coder-agent}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "instance: $INSTANCE_ID"

log "waiting for the instance to reach 'running'"
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

log "waiting for the SSM agent to register (bootstrap needs ~3-5 min)"
for _ in $(seq 1 30); do
  STATUS=$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  [ "$STATUS" = "Online" ] && break
  sleep 10
done

if [ "$STATUS" != "Online" ]; then
  echo "SSM agent not registered yet — the instance role may be missing" \
       "AmazonSSMManagedInstanceCore, or bootstrap is still running. Check:"
  echo "  aws ssm describe-instance-information --region $AWS_REGION"
  exit 1
fi

cat <<EOF

instance $INSTANCE_ID is up and SSM-registered.

  shell:   aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION
  console: aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION \\
             --document-name AWS-StartPortForwardingSession \\
             --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'

Bootstrap runs for a few minutes after this. Check progress with:
  aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION
  sudo tail -f /var/log/poc-bootstrap.log

When done for the day:
  aws ec2 stop-instances --region $AWS_REGION --instance-ids $INSTANCE_ID
EOF
