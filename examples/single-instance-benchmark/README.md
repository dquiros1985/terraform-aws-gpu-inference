# Single-instance GPU benchmark

The cheap way to get real numbers for the results table in the root README.

**Roughly $0.35/hour on spot.** A two-hour window costs about **$0.70**. There
is no EKS control plane and no NAT gateway, so nothing bills once the instance
is gone.

## It shuts itself off

Three independent mechanisms, because the realistic failure is forgetting
about it, not a technical fault:

1. **`shutdown -h +N` scheduled at boot** — the first line of user-data, before
   anything that could fail. Fires even if the container never starts.
2. **`instance_initiated_shutdown_behavior = "terminate"`** — makes that
   shutdown a *terminate*, not a stop. A stopped instance keeps billing for its
   EBS volume forever; this is the difference between $0 and a slow leak.
3. **Spot, one-time request** — AWS may reclaim it independently, and it will
   never be relaunched.

`max_runtime_minutes` defaults to **120** and is capped at 480. The
`terminates_at_utc` output prints the hard deadline at apply time.

## Run it

```bash
cd examples/single-instance-benchmark

# Restrict the inference port to yourself. The default reaches nothing.
export TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32"

eval "$(aws configure export-credentials --format env)"   # Terraform needs this
terraform init
terraform apply           # review the plan, note terminates_at_utc

bash benchmark.sh "$(terraform output -raw public_ip)"

terraform destroy -auto-approve    # do not wait for the deadman switch
```

Then confirm nothing survived:

```bash
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Purpose,Values=ephemeral-benchmark" \
            "Name=instance-state-name,Values=running,pending,stopped" \
  --query "Reservations[].Instances[].[InstanceId,State.Name]" --output table
```

An empty table means nothing is billing.

## What to record

Put these in the root README results table, with the raw output committed
under `docs/benchmarks/`:

- tokens/sec, single stream
- tokens/sec at 16 concurrent
- time to first token, p50 and p95
- end-to-end latency, p50 and p95
- GPU utilisation under load (`nvidia-smi dmon`)
- cost per 1M output tokens
- cold start, instance launch to first successful response

`benchmark.sh` covers the first two roughly. Install **k6** for real
percentiles — the shell loop measures wall-clock for a batch, not a latency
distribution, and the README should say which method produced each number.

## Honest limits

- Single GPU, single replica. Says nothing about autoscaling or multi-node
  behaviour — that is what the EKS module is for.
- Spot pricing floats by region and time of day. Record what you actually
  paid, not the estimate.
- Public subnet with one port open to one address. Fine for an ephemeral
  benchmark, not a pattern to copy into anything durable.
