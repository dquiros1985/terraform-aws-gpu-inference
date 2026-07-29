# terraform-aws-gpu-inference

Terraform module that stands up GPU-backed LLM inference on EKS: cluster, GPU
capacity, vLLM serving, autoscaling and observability. One `terraform apply`,
one `terraform destroy`.

> **Status: work in progress.** The GPU nodegroup module is implemented and
> `terraform validate` passes on the root module and the example. Serving and
> observability are still stubs, and nothing here has been applied against a
> live cluster yet. The results table below is empty on purpose — I do not
> publish numbers I have not measured. See [Roadmap](#roadmap).

## Why this exists

Most GPU inference setups I've seen start as a notebook and a shell script on
someone's laptop. That works exactly until the person who wrote it is on leave
and a node dies at 2am.

I spent eight years making CI/CD, Kubernetes and observability reproducible for
banks, telecoms and a regulated clinical platform. This module applies the same
discipline to LLM serving: the infrastructure is code, the cost is visible, the
latency is measured, and tearing it down is a single command rather than an
archaeology exercise across the AWS console.

## Architecture

```
                    ┌─────────────────────────────────┐
   client ────────► │  ALB / Ingress                  │
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │  vLLM  (OpenAI-compatible API)  │
                    │  HPA / KEDA on queue depth      │
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │  GPU nodegroup                  │
                    │  Karpenter · spot-first         │
                    │  NVIDIA GPU Operator            │
                    └──────────────┬──────────────────┘
                                   │
                    ┌──────────────▼──────────────────┐
                    │  Prometheus · DCGM · Grafana    │
                    │  tokens/s · TTFT · p95 · $/1M   │
                    └─────────────────────────────────┘
```

## Usage

```hcl
module "gpu_inference" {
  source = "github.com/dquiros1985/terraform-aws-gpu-inference"

  cluster_name = "gpu-inference-demo"
  region       = "us-west-2"

  model_id     = "meta-llama/Llama-3.1-8B-Instruct"
  quantization = "awq"

  capacity_type = "spot"
  max_replicas  = 2
}
```

```bash
terraform init && terraform apply
curl "$(terraform output -raw inference_endpoint)/v1/models"

bash scripts/teardown.sh   # destroy + verify nothing is still billing
```

Read [Cost](#cost--read-before-applying) first. An idle EKS cluster still
costs roughly $73/month.

A complete example lives in [`examples/complete`](examples/complete).

## Results

Measured on the reference configuration. **Empty until I have run the
benchmark myself** — see the note at the top.

| Metric | Value |
| --- | --- |
| Model / quantization | — |
| GPU / instance type | — |
| Tokens/sec (single stream) | — |
| Tokens/sec (16 concurrent) | — |
| Time to first token, p50 / p95 | — |
| End-to-end latency, p50 / p95 | — |
| GPU utilisation under load | — |
| Cost per 1M output tokens | — |
| Cold start (node → ready) | — |

Method: k6 against the OpenAI-compatible endpoint, fixed prompt distribution,
warm cache excluded from the first window. Raw output will be committed under
`docs/benchmarks/` so the numbers can be checked rather than taken on trust.

## Cost — read before applying

**There is no zero-cost idle state for this stack.** An EKS cluster bills a
flat control-plane fee whether or not a single pod is running, so "scaled to
zero" still costs money. Only "destroyed" is free.

| Component | Rate | Idle cost |
| --- | --- | --- |
| EKS control plane | ~$0.10/hr | **~$73/mo, always** — no scale-to-zero |
| NAT gateway (per AZ) | ~$0.045/hr | ~$32/mo each, plus data processing |
| GPU node, `g5.xlarge` on-demand | ~$1.00/hr | $0 when Karpenter scales to zero |
| GPU node, `g5.xlarge` spot | ~$0.35/hr | $0 when scaled to zero |
| EBS root volume, 200Gi gp3 | ~$16/mo per node | billed while the volume exists |

Rates are US West (Oregon) and drift. Confirm against the AWS pricing pages
before relying on them.

**What scales to zero:** GPU nodes. Karpenter removes them when no GPU pod is
pending, so an idle cluster runs no GPU cost.

**What does not:** the control plane, NAT gateways, and any EBS volume that
outlives its node. A cluster left up over a weekend with zero traffic still
costs roughly $2-3/day.

### Working safely

1. **Set the budget alarm first**, before the first apply — `modules/cost-guardrails`
   creates an AWS Budget with alerts at 50/80/100 percent. Confirm the SNS
   subscription email or the alerts go nowhere. Note that budget alerts
   *notify*, they do not cap: AWS has no hard spending limit.
2. **Time-box the run.** Apply, benchmark, destroy in one sitting. A full
   benchmark session is one to two hours, so roughly $2-5 all in.
3. **Always finish with `bash scripts/teardown.sh`.** It destroys the stack
   and then checks for orphans Terraform does not track — Karpenter creates
   nodes outside the state file, and a partly failed destroy can strand them.
4. **Never leave a cluster up overnight** to "carry on tomorrow". Destroy and
   re-apply; that is what the module is for.

### Cheaper route to the same benchmark numbers

If the goal is the results table rather than the Kubernetes machinery, skip
EKS. A single `g5.xlarge` spot instance running vLLM directly gives you real
tokens/sec, time-to-first-token and p95 latency for about **$0.35/hour** —
under a dollar for a full benchmark, with no control-plane fee and no NAT
gateway.

Those numbers are equally valid for the results table, as long as the method
section says how they were measured. The EKS module is about reproducible
provisioning; the benchmark is about model throughput. They can be proven
separately.


## Design decisions

**Karpenter over managed nodegroups.** GPU capacity is scarce and regional.
Karpenter falls through an ordered instance-type list when the preferred type
is unavailable, which is the difference between degraded service and no
service.

**Spot by default.** GPU spot is dramatically cheaper and inference is
interruption-tolerant if you drain properly. The two-minute reclaim warning is
enough to finish in-flight requests. Set `capacity_type = "on-demand"` when
that tradeoff is wrong for you.

**NVIDIA GPU Operator rather than baked drivers.** Installing drivers in a
launch template works until the first AMI update, then breaks silently. The
operator owns driver, container toolkit and device plugin as one lifecycle.

**Autoscale on queue depth, not CPU.** CPU utilisation is close to meaningless
for GPU-bound inference. Scaling on it produces a service that is simultaneously
over-provisioned and slow.

**Readiness probes sized for model load.** An 8B model takes roughly one to two
minutes to load into GPU memory. Default probe timings restart-loop forever and
the failure looks like a crash rather than a config error.

## Tradeoffs and limits

- Single-region, single-cluster. No multi-region failover.
- One model per deployment. Multi-model routing belongs in a gateway in front
  of this, not inside it.
- No authentication on the inference endpoint by default. Put a gateway or
  ALB authorizer in front before exposing it beyond a VPC.
- Spot interruption is handled by draining, not by request replay. A client
  retry policy is still required.
- Cost output is an estimate from instance pricing, not billed spend. Confirm
  against Cost Explorer.

## Roadmap

- [ ] VPC and EKS control plane via upstream modules
- [x] Karpenter NodePool + EC2NodeClass + NVIDIA GPU Operator
- [ ] Apply against a live cluster and fix what breaks
- [ ] vLLM deployment, service, HPA/KEDA
- [ ] kube-prometheus-stack, DCGM exporter, Grafana dashboards
- [ ] Benchmark harness and published results
- [x] Cost estimation output (static table; Pricing API later)
- [x] Budget alarms and teardown-with-orphan-check script
- [ ] Terratest coverage

## CI

Every push runs `terraform fmt -check`, `validate` against the root module and
the example, plus tfsec and Checkov. See
[`.github/workflows/terraform.yml`](.github/workflows/terraform.yml).

## License

MIT — see [LICENSE](LICENSE).
