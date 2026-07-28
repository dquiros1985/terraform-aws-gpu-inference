# Minimal working example.
#
#   terraform init && terraform apply
#   curl "$(terraform output -raw inference_endpoint)/v1/models"
#
# Tear down with `terraform destroy` when finished. GPU nodes are the most
# expensive thing in this stack by an order of magnitude.

module "gpu_inference" {
  source = "../../"

  cluster_name = "gpu-inference-demo"
  region       = "us-west-2"

  model_id     = "meta-llama/Llama-3.1-8B-Instruct"
  quantization = "awq"

  capacity_type = "spot"
  max_replicas  = 2

  tags = {
    Environment = "demo"
    Owner       = "david"
  }
}

output "endpoint" {
  value = module.gpu_inference.inference_endpoint
}
