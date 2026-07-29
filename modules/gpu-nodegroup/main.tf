# ---------------------------------------------------------------------------
# GPU capacity for the cluster.
#
# Two pieces: Karpenter resources that decide what to launch, and the NVIDIA
# GPU Operator that makes a launched instance usable as a GPU node.
#
# Ordering matters. The GPU Operator must be installed before the first GPU
# pod schedules, or the pod sits Pending with no allocatable nvidia.com/gpu
# resource and the cause is not obvious from the pod events.
# ---------------------------------------------------------------------------

locals {
  gpu_taint_key = "nvidia.com/gpu"
}

# The GPU Operator owns driver, container toolkit, device plugin and DCGM
# exporter as a single lifecycle. Installing drivers through userData or a
# custom AMI works until the first AMI update, then breaks silently on the
# next node replacement.
resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://nvidia.github.io/gpu-operator"
  chart            = "gpu-operator"
  version          = var.gpu_operator_version
  namespace        = "gpu-operator"
  create_namespace = true

  # Driver install takes several minutes on first boot.
  timeout = 900
  wait    = true

  # AL2023 accelerated AMIs already carry the driver, so the operator should
  # not try to install its own. Set to true only on a distro without it.
  set {
    name  = "driver.enabled"
    value = "false"
  }

  set {
    name  = "toolkit.enabled"
    value = "true"
  }

  # DCGM exporter is what makes GPU utilisation and memory visible to
  # Prometheus. Without it you are flying blind on the most expensive
  # resource in the cluster.
  set {
    name  = "dcgmExporter.enabled"
    value = "true"
  }

  set {
    name  = "dcgmExporter.serviceMonitor.enabled"
    value = "true"
  }

  # Tolerate the taint applied by the NodePool below, otherwise the operator's
  # own DaemonSets cannot land on the nodes they are meant to configure.
  set {
    name  = "daemonsets.tolerations[0].key"
    value = local.gpu_taint_key
  }

  set {
    name  = "daemonsets.tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "daemonsets.tolerations[0].effect"
    value = "NoSchedule"
  }
}

# EC2NodeClass: the AWS-side template. Subnets and security groups are
# discovered by tag rather than hardcoded, so this module does not need to
# know the VPC layout.
resource "kubernetes_manifest" "gpu_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu"
    }
    spec = {
      role = var.node_iam_role_name

      amiSelectorTerms = [
        { alias = var.ami_alias }
      ]

      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]

      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "${var.disk_size_gi}Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
            # gp3 baseline throughput is 125 MB/s. Model loading is a large
            # sequential read; raising this measurably cuts cold start.
            throughput = 250
          }
        }
      ]

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 1
      }

      tags = var.tags
    }
  }
}

# NodePool: the scheduling-side policy. Karpenter consults this to decide
# whether a pending pod justifies launching a node, and which node.
resource "kubernetes_manifest" "gpu_node_pool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }

          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = var.instance_types
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              # Listing on-demand alongside spot lets Karpenter fall back
              # rather than fail when spot GPU capacity is exhausted.
              values = var.capacity_type == "spot" ? ["spot", "on-demand"] : ["on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            }
          ]

          # Reserve these nodes for workloads that actually need a GPU.
          # Without the taint, ordinary pods land on them and you pay GPU
          # prices to run a sidecar.
          taints = [
            {
              key    = local.gpu_taint_key
              value  = "true"
              effect = "NoSchedule"
            }
          ]

          # Replace nodes on a schedule so AMI and driver updates land, and
          # so a long-lived spot node does not drift from the fleet.
          expireAfter = "720h"
        }
      }

      limits = {
        cpu = var.cpu_limit
      }

      disruption = {
        # Consolidate only when empty. WhenEmptyOrUnderutilized will evict
        # in-flight inference to repack, which shows up as user-visible
        # latency spikes rather than as a cost saving.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "5m"
      }
    }
  }

  depends_on = [kubernetes_manifest.gpu_node_class]
}
