output "vpc_id" {
  description = "VPC ID。"
  value       = huaweicloud_vpc.this.id
}

output "apig_instance_id" {
  description = "APIG 专享版实例 ID。"
  value       = huaweicloud_apig_instance.this.id
}

output "apig_private_ingress_address" {
  description = "APIG 专享版实例的内网入口地址，由资源直接导出。"
  value       = huaweicloud_apig_instance.this.vpc_ingress_address
}

output "apig_public_ingress_address" {
  description = "APIG 公网入口地址。本实践刻意不绑 EIP，正常应为空——非空即说明架构约束被破坏。"
  value       = huaweicloud_apig_instance.this.ingress_address
}

output "api_group_id" {
  description = "API 分组 ID。"
  value       = huaweicloud_apig_group.this.id
}

output "api_group_domain" {
  description = "API 分组调试域名。它是 APIG 路由的唯一 Host 依据，调用时必须带上。"
  value       = local.group_domain
}

output "elb_private_ip" {
  description = "内网 ELB 的私网 IP，是整条链路对外的唯一入口。"
  value       = huaweicloud_elb_loadbalancer.this.ipv4_address
}

output "bastion_public_ip" {
  description = "跳板机公网 IP。"
  value       = var.enable_bastion ? huaweicloud_vpc_eip.bastion[0].address : null
}

output "bastion_password" {
  description = "跳板机 root 密码（随机生成）。用 terraform output -raw bastion_password 取值。"
  value       = var.enable_bastion ? random_password.bastion[0].result : null
  sensitive   = true
}

output "verify_command" {
  description = <<-EOT
    在跳板机上执行的验证命令。
    -k 是因为 ELB 用的是自签名证书；-H Host 是因为 APIG 靠 Host 头路由到分组。
  EOT
  value = join(" ", [
    "curl -sS -k -i",
    "-H 'Host: ${local.group_domain}'",
    "https://${huaweicloud_elb_loadbalancer.this.ipv4_address}${var.api_request_path}",
  ])
}

output "negative_check_command" {
  description = "反向验证：直连 APIG 内网地址应当通，而任何公网路径都不通（网关无 EIP）。"
  value = join(" ", [
    "curl -sS -k -i",
    "-H 'Host: ${local.group_domain}'",
    "https://${huaweicloud_apig_instance.this.vpc_ingress_address}${var.api_request_path}",
  ])
}
