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

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
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
  subnet_id     = data.aws_subnets.default.ids[0]
  key_name      = var.key_name

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
