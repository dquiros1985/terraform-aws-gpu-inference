#!/usr/bin/env bash
# Destroy everything this module created, and prove it is gone.
#
# GPU nodes and the EKS control plane bill continuously. The control plane
# charges roughly $0.10/hour whether or not a single pod is running, so
# "scaled to zero" is NOT free - only "destroyed" is free.
#
# Usage: bash scripts/teardown.sh [aws-region]
set -euo pipefail

REGION="${1:-us-west-2}"

echo "This destroys all infrastructure in this Terraform state."
echo "Region: $REGION"
read -r -p "Type DESTROY to continue: " CONFIRM
[ "$CONFIRM" = "DESTROY" ] || { echo "Aborted."; exit 1; }

echo
echo "######## TERRAFORM DESTROY ########"
terraform destroy -auto-approve

echo
echo "######## ORPHAN CHECK ########"
echo "Terraform state is not the whole truth: Karpenter creates nodes outside"
echo "of it, and a destroy that fails partway can strand them. Checking."
echo
echo "--- running GPU instances ---"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[?starts_with(InstanceType,'g') || starts_with(InstanceType,'p')].[InstanceId,InstanceType,LaunchTime]" \
  --output table

echo "--- EKS clusters (each bills ~\$0.10/hr even when idle) ---"
aws eks list-clusters --region "$REGION" --output table

echo "--- NAT gateways (~\$0.045/hr each) ---"
aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].[NatGatewayId,VpcId]" --output table

echo "--- unattached EBS volumes (billed while they exist) ---"
aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size,CreateTime]" --output table

echo
echo "Empty tables above mean nothing is billing. Anything listed needs"
echo "removing by hand."
