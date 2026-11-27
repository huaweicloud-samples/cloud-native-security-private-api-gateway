# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------

variable "region" {
  description = "部署区域。APIG 专享版与独享型 ELB 的规格目录按区域略有差异。"
  type        = string
  default     = "cn-south-1"
}

variable "name_prefix" {
  description = "资源名前缀。所有资源名形如 <prefix>-<角色>-<随机后缀>。"
  type        = string
  default     = "cf2privapi"
}

variable "enterprise_project_id" {
  description = "企业项目 ID。留空表示使用默认企业项目。"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 网络
#
# 一个 VPC + 两个子网。
# 独享型 ELB 的可用区数量会影响规格选型，故默认只占一个可用区，
# 第二个子网保留用于后续扩展。
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC 网段。"
  type        = string
  default     = "192.168.0.0/16"
}

variable "subnet_a_cidr" {
  description = "主子网网段。ELB 与 APIG 专享版实例都落在这里。"
  type        = string
  default     = "192.168.0.0/24"
}

variable "subnet_b_cidr" {
  description = "备子网网段，用于扩展。"
  type        = string
  default     = "192.168.1.0/24"
}

variable "availability_zones" {
  description = <<-EOT
    部署可用区列表，留空则取本区域可用区列表的第一个。
    可用区数量会影响独享型 ELB 的规格选型，默认只用一个。
    若 APIG 专享版在该可用区无库存（报 APIG.xxxx / 资源售罄），换一个可用区重试。
  EOT
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# APIG 专享版
#
# APIG 专享版实例。
# 专享版实例部署在 VPC 内并导出 vpc_ingress_address，内网入口由实例直接提供。
# ---------------------------------------------------------------------------

variable "apig_edition" {
  description = <<-EOT
    APIG 专享版规格。BASIC 是最小规格。
    可选：BASIC / PROFESSIONAL / ENTERPRISE / PLATINUM。
    按实际需求选择规格。
  EOT
  type        = string
  default     = "BASIC"

  validation {
    condition     = contains(["BASIC", "PROFESSIONAL", "ENTERPRISE", "PLATINUM"], var.apig_edition)
    error_message = "apig_edition 只能是 BASIC / PROFESSIONAL / ENTERPRISE / PLATINUM。"
  }
}

variable "apig_bind_eip" {
  description = <<-EOT
    是否给 APIG 专享版实例绑定公网入口 EIP。
    本实践的核心约束就是「API 网关零公网入口」，必须保持 false。
    置为 true 会直接推翻本实践的架构意图。
  EOT
  type        = bool
  default     = false
}

variable "api_name" {
  description = "MOCK API 的名称。"
  type        = string
  default     = "hello_api"
}

variable "api_request_path" {
  description = "API 请求路径。"
  type        = string
  default     = "/hello"
}

variable "api_mock_response" {
  description = "MOCK 后端返回体。"
  type        = string
  default     = "{\"message\": \"Hello from API GW\"}"
}

# ---------------------------------------------------------------------------
# 独享型 ELB
#
# 独享型 ELB（内网 L7 入口）。
# ---------------------------------------------------------------------------

variable "elb_flavor_type" {
  description = <<-EOT
    七层规格类型。取 "L7" 表示固定规格。
    不要取 "L7_elastic_max"——那是弹性最大规格，上限 1000 LCU，规格会显著变大。
  EOT
  type        = string
  default     = "L7"
}

variable "elb_flavor_name" {
  description = <<-EOT
    七层规格名称，必须精确指定。
    绝不使用 data.huaweicloud_elb_flavors.*.ids[N] 让系统随机挑选：
    该数据源按 flavor UUID 字典序返回，顺序与规格大小无关，
    随机命中大规格会导致资源规格与预期不符。
    若本区域没有该名称，先 `terraform console` 实查 data.huaweicloud_elb_flavors.l7 再改。
  EOT
  type        = string
  default     = "L7_flavor.elb.s1.small"
}

variable "elb_allowed_cidrs" {
  description = <<-EOT
    允许访问 ELB 监听器的来源网段白名单。
    独享型 ELB 没有安全组概念，访问控制靠监听器绑定 IP 地址组实现。
    留空表示不启用白名单。
  EOT
  type        = list(string)
  default     = ["192.168.0.0/16"]
}

variable "apig_backend_protocol" {
  description = <<-EOT
    ELB 到 APIG 这一跳的协议。默认 HTTP。
    原因：APIG 专享版内网入口的 443 只有在绑定证书后才会监听，本实践无自有域名、
    不绑证书，因此 443 实际不开放；只有 80（HTTP）始终可用。
    故回源用 HTTP（监听器的 TLS 已在 ELB 处用自签名证书终结，VPC 内这一跳明文足够），
    既绕开 APIG 证书依赖，又让健康检查（HTTP + Host 头）能正常按 Host 路由到分组。
    如后续给 APIG 绑定了证书，可改回 HTTPS。
  EOT
  type        = string
  default     = "HTTP"

  validation {
    condition     = contains(["HTTP", "HTTPS"], var.apig_backend_protocol)
    error_message = "apig_backend_protocol 只能是 HTTP 或 HTTPS。"
  }
}


# ---------------------------------------------------------------------------
# 自签名证书
#
# 使用者无域名、无证书，故 HTTPS 用自签名证书打通，客户端须 curl -k。
# 生产环境必须替换为可信 CA 证书。
# ---------------------------------------------------------------------------

variable "tls_common_name" {
  description = "自签名证书的 CN。无真实域名，仅用于填充证书主体。"
  type        = string
  default     = "private-apigw.internal"
}

variable "tls_validity_hours" {
  description = "自签名证书有效期（小时）。默认 90 天。"
  type        = number
  default     = 2160
}

# ---------------------------------------------------------------------------
# 跳板机
#
# ELB 是内网的，VPC 外无法直接验证。跳板机是 VPC 内的验证入口。
# ---------------------------------------------------------------------------

variable "enable_bastion" {
  description = "是否创建跳板 ECS + EIP。验证完成后可置 false 单独销毁以止血。"
  type        = bool
  default     = true
}

variable "bastion_flavor_id" {
  description = <<-EOT
    跳板机规格 ID，直接写死而非用数据源下标挑选——规格直接决定资源能力。
    s6.small.1 = 1 vCPU / 1 GiB，够跑 curl。
  EOT
  type        = string
  default     = "s6.small.1"
}

variable "bastion_image_name_regex" {
  description = "跳板机公共镜像名称正则。区域间镜像名有差异，命中失败时用 terraform console 实查后覆盖。"
  type        = string
  default     = "^Huawei Cloud EulerOS 2\\.0 Standard 64 bit.*"
}

variable "bastion_image_architecture" {
  description = <<-EOT
    跳板机镜像架构，必须与 bastion_flavor_id 的架构一致。
    同名镜像同时存在 x86 与 ARM 两版，不指定会随机命中 ARM 导致 ECS 创建失败。
    s6.small.1 是 x86 规格，故默认 x86。
  EOT
  type        = string
  default     = "x86"
}

variable "bastion_ssh_source_cidr" {
  description = <<-EOT
    允许 SSH 登录跳板机的来源网段。**必须显式指定为你的出口 IP/32**。
    留空会导致创建失败——不允许 0.0.0.0/0 这种默认放通。
  EOT
  type        = string
  default     = ""
}

variable "bastion_eip_bandwidth_mbit" {
  description = "跳板机 EIP 带宽上限（Mbit/s），上限只影响峰值速率。"
  type        = number
  default     = 5
}
