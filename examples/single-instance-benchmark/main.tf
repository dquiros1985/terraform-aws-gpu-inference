# ---------------------------------------------------------------------------
# Single-instance GPU benchmark - the cheap path to real numbers.
#
# No EKS, no control-plane fee, no NAT gateway. One spot GPU instance in the
# default VPC, running vLLM, that terminates itself.
#
# Why this exists: the EKS module proves reproducible provisioning. This
# proves model throughput. Different claims, and two orders of magnitude
# apart to demonstrate - roughly $0.35/hour here against a ~$73/month floor
# for a cluster that bills whether or not anything runs.
#
# THREE independent shutdown mechanisms, because one is not enough when the
# real failure mode is "forgot about it for a week":
#   1. `shutdown -h +N` scheduled at boot   - fires even if vLLM never starts
#   2. instance_initiated_shutdown_behavior - makes that shutdown a TERMINATE,
#                                             not a stop that keeps billing EBS
#   3. spot + one-time request              - AWS may reclaim it anyway, and
#                                             it will never be relaunched
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_vpc" "default" {
  default = true
}

# Not every Availability Zone offers every instance type, and the default VPC
# has a subnet in every AZ. In us-west-2 the default VPC includes us-west-2d,
# which does not offer g5 at all - so taking subnets[0] blindly is a coin flip
# that fails with "Unsupported ... in your requested Availability Zone", and it
# fails at RunInstances, after the security group already exists.
#
# Ask AWS which AZs actually offer this instance type, then only consider
# subnets that sit in one of them.
data "aws_ec2_instance_type_offerings" "gpu" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }

  location_type = "availability-zone"
}

data "aws_subnets" "gpu_capable" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.gpu.locations
  }
}

# Preflight: a new AWS account has a GPU quota of ZERO, and the failure is
# opaque. RunInstances returns "MaxSpotInstanceCountExceeded", which reads like
# "you have too many running" when the truth is "you are allowed none". Check
# during plan instead, so nobody burns a credential export, a security group
# and a failed apply to discover it.
#
# The quota is measured in vCPUs. This checks only that it is non-zero, which
# is the case that actually bites; a quota of 4 with a 8-vCPU instance type
# would still fail at apply.
#
# Requires servicequotas:GetServiceQuota. Set preflight_quota_check = false if
# the caller does not have it.
data "aws_servicequotas_service_quota" "gpu_spot" {
  count        = var.preflight_quota_check ? 1 : 0
  service_code = "ec2"
  quota_code   = "L-3819A6DF" # All G and VT Spot Instance Requests
}

# The Deep Learning AMI ships the NVIDIA driver, CUDA and Docker already.
# Installing those from a bare AMI burns 15 minutes of paid GPU time per run.
data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver AMI GPU PyTorch*Ubuntu 22.04*"]
  }
}

resource "aws_security_group" "bench" {
  name_prefix = "gpu-bench-"
  description = "vLLM inference port, restricted to a single address"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "vLLM OpenAI-compatible API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "Model download and container pull"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "gpu-bench"
    Purpose = "ephemeral-benchmark"
  }
}

locals {
  user_data = <<-BASH
    #!/bin/bash
    set -x

    # ---- DEADMAN SWITCH -------------------------------------------------
    # First statement, before anything that could fail. With
    # instance_initiated_shutdown_behavior = "terminate", this guarantees the
    # instance destroys itself even if every later step breaks.
    shutdown -h +${var.max_runtime_minutes} "benchmark window expired"
    echo "auto-terminate scheduled +${var.max_runtime_minutes} min" > /var/log/deadman.log

    # ---- serve ----------------------------------------------------------
    docker run -d --restart no --gpus all -p 8000:8000 --name vllm \
      vllm/vllm-openai:latest \
      --model ${var.model_id} \
      --quantization awq \
      --max-model-len 4096 \
      --gpu-memory-utilization 0.90

    for i in $(seq 1 90); do
      curl -sf http://localhost:8000/v1/models && touch /tmp/vllm-ready && break
      sleep 10
    done
  BASH
}

resource "aws_instance" "bench" {
  ami           = data.aws_ami.dlami.id
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.gpu_capable.ids[0]
  key_name      = var.key_name

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.gpu_capable.ids) > 0
      error_message = "No subnet in the default VPC of ${var.region} sits in an Availability Zone that offers ${var.instance_type}. Pick another region, or another instance type."
    }

    precondition {
      condition     = !var.preflight_quota_check || one(data.aws_servicequotas_service_quota.gpu_spot[*].value) > 0
      error_message = "EC2 quota 'All G and VT Spot Instance Requests' (L-3819A6DF) is 0 vCPUs in ${var.region}: no G-family GPU instance can launch here at any size. This is an account limit, not a configuration error. Request an increase in Service Quotas, wait for approval, then re-run."
    }
  }

  vpc_security_group_ids = [aws_security_group.bench.id]

  # Without this, `shutdown -h` merely stops the instance - and a stopped
  # instance keeps billing for its EBS volume indefinitely.
  instance_initiated_shutdown_behavior = "terminate"

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
      max_price                      = var.max_spot_price_usd
    }
  }

  root_block_device {
    volume_size           = 120
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = local.user_data

  tags = {
    Name           = "gpu-bench"
    Purpose        = "ephemeral-benchmark"
    AutoTerminates = "${var.max_runtime_minutes}m"
  }
}
