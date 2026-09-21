locals {
  module_name = basename(abspath(path.module))
  prefix      = var.prefix
  ec2_dns     = try(data.aws_ssm_parameter.ec2_dns.value, var.ec2_dns)
}
