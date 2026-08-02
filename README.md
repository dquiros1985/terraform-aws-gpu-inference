# terraform-aws-gpu-inference

![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-FFDD00?style=flat&logo=buymeacoffee&logoColor=black)

Terraform module that stands up GPU-backed LLM inference on EKS: cluster, GPU
capacity, vLLM serving, autoscaling and observability. One `terraform apply`,
one `terraform destroy`.

> **Status: work in progress.** The GPU nodegroup module is implemented and
> `terraform validate` passes on the root module and the example. Serving and
> observability are still stubs, and nothing here has been applied against a
> live cluster yet. The results table below is empty on purpose — I do not
> publish numbers I have not measured. See [Roadmap](#roadmap).

## What this does, in plain language

Running a large language model on your own hardware normally means a person
clicking through the AWS console, installing GPU drivers by hand, starting a
server, and hoping they remember to switch it all off. This repository replaces
that with code you run.

There are **two separate paths**, because they answer two different questions.

**Path A — the full stack on Kubernetes.** Answers *"can this be rebuilt
identically, by anyone, on demand?"* Costs about $73/month minimum, because a
Kubernetes control plane bills around the clock.

**Path B — one machine, for benchmarking.** Answers *"how fast is the model,
really?"* Costs about $0.35/hour and switches itself off. No Kubernetes.

### The pieces, and what each one is for

| Piece | What it actually does |
| --- | --- |
| `modules/gpu-nodegroup` | Rents GPU machines from AWS **only while something needs one**, and hands them back when the work stops. Uses Karpenter, which tries a list of machine types in order — GPUs are often sold out in a region, so asking for one specific type means getting nothing. |
| NVIDIA GPU Operator | Installs and maintains the GPU drivers **automatically**. Baking drivers into a machine image works until the image updates, then breaks quietly at 2am. |
| `modules/vllm-serving` | Runs **vLLM**, the program that actually loads the model and answers questions. It speaks the same API shape as OpenAI, so existing client code works unchanged. *(Still a stub.)* |
| Autoscaling | Adds more copies when requests pile up, removes them when the queue empties. It watches the **queue**, not CPU — CPU means almost nothing for a GPU workload, and scaling on it gives you something both expensive and slow. |
| `modules/observability` | Collects the numbers that matter: tokens per second, how long until the first word appears, slow-request outliers, and how hard the GPU is working. Prometheus + Grafana + NVIDIA's DCGM exporter. *(Still a stub.)* |
| `modules/cost-guardrails` | Sets up an **AWS budget alarm** that emails you at 50%, 80% and 100% of a limit you choose. Set this up before your first apply. Note it **warns**, it does not stop spending — AWS has no hard cap. |
| `scripts/teardown.sh` | Destroys everything, then **checks that it really is gone**. Terraform does not know about machines Karpenter created on its own, and a destroy that fails halfway can leave things running and billing. This looks for those leftovers by hand. |
| `examples/single-instance-benchmark` | Path B. One GPU machine, running vLLM directly, that **deletes itself**. See below. |

### How the benchmark machine switches itself off

The realistic failure mode is not a bug. It is forgetting. So there are three
independent mechanisms, and any one of them is enough:

1. **A countdown started at boot.** The machine schedules its own shutdown
   before it does anything else, so it fires even if the model never loads.
2. **Shutdown means delete, not pause.** A paused machine keeps charging for its
   disk forever. This one is configured to destroy itself instead.
3. **It is rented as a one-time spot instance.** AWS may reclaim it early, and
   when it does, nothing restarts it.

You can also just run `terraform destroy` the moment you have your numbers.

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

**Empty until I have run it myself.** I do not publish numbers I have not
measured, and I do not publish a number from a tool that cannot measure it.

### Path B — single instance (`examples/single-instance-benchmark`)

These are the fields `benchmark.sh` can actually produce.

| Metric | Value |
| --- | --- |
| Model / quantization | — |
| GPU / instance type | — |
| Tokens/sec, single stream | — |
| Tokens/sec, 16 concurrent (upper bound) | — |
| Time from boot to first successful request | — |
| Spot price paid, per hour | — |
| Cost per 1M output tokens *(derived)* | — |

Method: `benchmark.sh` against the vLLM OpenAI-compatible endpoint. One
fixed-prompt request at `temperature=0` for the single-stream figure, then 16
parallel requests timed as one batch. Raw terminal output committed under
`docs/benchmarks/` so the numbers can be checked rather than taken on trust.

Two honest caveats, stated here rather than buried:

- **The 16-concurrent figure is an upper bound, not a measurement.** It divides
  total possible tokens by wall-clock time, and not every request reaches
  `max_tokens`. Real aggregate throughput is lower.
- **Cost per 1M tokens is arithmetic, not billing.** It is the measured
  throughput against the spot price paid. Confirm against Cost Explorer before
  quoting it anywhere that matters.

### Percentiles and time-to-first-token — not yet measured

`benchmark.sh` measures wall-clock for a batch. It does **not** produce a
latency distribution, so there is nothing here to report yet.

| Metric | Value | Needs |
| --- | --- | --- |
| Time to first token, p50 / p95 | — | k6 or equivalent, streaming enabled |
| End-to-end latency, p50 / p95 | — | k6 or equivalent |
| GPU utilisation under load | — | DCGM exporter (Path A) |

A single request timed with `curl` is a sample of one. Publishing a p95 from it
would be inventing a number, so these rows stay empty until there is a load
generator behind them.

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
