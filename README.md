# terraform-aws-gpu-inference

Terraform module that stands up GPU-backed LLM inference on EKS: cluster, GPU
capacity, vLLM serving, autoscaling and observability. One `terraform apply`,
one `terraform destroy`.

> **Status: work in progress.** The structure, interface and CI are in place;
> the module bodies are being implemented. The results table below is empty on
> purpose — I do not publish numbers I have not measured. See
> [Roadmap](#roadmap).

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
terraform destroy   # GPU nodes are expensive - do not leave them running
```

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
- [ ] Karpenter provisioner + NVIDIA GPU Operator
- [ ] vLLM deployment, service, HPA/KEDA
- [ ] kube-prometheus-stack, DCGM exporter, Grafana dashboards
- [ ] Benchmark harness and published results
- [ ] Cost estimation output
- [ ] Terratest coverage

## CI

Every push runs `terraform fmt -check`, `validate` against the root module and
the example, plus tfsec and Checkov. See
[`.github/workflows/terraform.yml`](.github/workflows/terraform.yml).

## License

MIT — see [LICENSE](LICENSE).
