# ===========================================================================
# 华为云 API 网关私网入口最佳实践
#
# 架构：VPC 内客户端 → 独享型 ELB(L7/内网/HTTPS) → APIG 专享版(仅内网)
#                 → API 分组 → MOCK API
# 入口策略：API 网关零公网入口，外部仅能经内网 ELB 单点访问
# ===========================================================================

locals {
  suffix = random_id.suffix.hex
  name   = "${var.name_prefix}-${local.suffix}"

  azs = length(var.availability_zones) > 0 ? var.availability_zones : [
    data.huaweicloud_availability_zones.this.names[0],
  ]

  # ELB → APIG 这一跳的端口由协议决定。APIG 专享版内网入口同时监听 80 / 443。
  apig_backend_port = var.apig_backend_protocol == "HTTPS" ? 443 : 80

  # APIG 靠 Host 头把请求路由到 API 分组。分组的调试域名（sl_domain）就是
  # 唯一可用的 Host —— 使用者无自有域名，无法绑定独立域名。
  # ELB 健康检查、客户端调用都必须带上它，否则 APIG 回 APIG.0101。
  group_domain = data.huaweicloud_apig_groups.this.groups[0].sl_domain

  enable_ip_group = length(var.elb_allowed_cidrs) > 0

  common_tags = {
    workload = "private-apigw-entry"
    origin   = "private-apigw-practice"
  }
}

data "huaweicloud_availability_zones" "this" {}

# ---------------------------------------------------------------------------
# 网络（一个 VPC + 两个子网）
# ---------------------------------------------------------------------------

resource "huaweicloud_vpc" "this" {
  name                  = "${local.name}-vpc"
  cidr                  = var.vpc_cidr
  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
  tags                  = local.common_tags
}

resource "huaweicloud_vpc_subnet" "a" {
  name       = "${local.name}-subnet-a"
  vpc_id     = huaweicloud_vpc.this.id
  cidr       = var.subnet_a_cidr
  gateway_ip = cidrhost(var.subnet_a_cidr, 1)

  availability_zone = local.azs[0]
  tags              = local.common_tags
}

resource "huaweicloud_vpc_subnet" "b" {
  name       = "${local.name}-subnet-b"
  vpc_id     = huaweicloud_vpc.this.id
  cidr       = var.subnet_b_cidr
  gateway_ip = cidrhost(var.subnet_b_cidr, 1)

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# 安全组
#
# APIG 实例的安全组为声明式配置，直接声明放通 VPC 网段即可。
# ---------------------------------------------------------------------------

resource "huaweicloud_networking_secgroup" "apig" {
  name                  = "${local.name}-apig-sg"
  description           = "APIG dedicated instance ingress, reachable from the ELB only"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
}

# ELB 的后端流量与健康检查从负载均衡器所在子网发起，故按 VPC 网段放通。
resource "huaweicloud_networking_secgroup_rule" "apig_from_vpc" {
  for_each = toset(["80", "443"])

  security_group_id = huaweicloud_networking_secgroup.apig.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  remote_ip_prefix  = var.vpc_cidr
  description       = "Allow ELB data plane and health check"
}

resource "huaweicloud_networking_secgroup" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                  = "${local.name}-bastion-sg"
  description           = "Bastion host for in-VPC verification"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
}

resource "huaweicloud_networking_secgroup_rule" "bastion_ssh" {
  count = var.enable_bastion ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.bastion[0].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.bastion_ssh_source_cidr
  description       = "SSH from the operator only"

  lifecycle {
    precondition {
      condition     = var.bastion_ssh_source_cidr != "" && var.bastion_ssh_source_cidr != "0.0.0.0/0"
      error_message = "bastion_ssh_source_cidr 必须显式设置为你的出口 IP/32，不接受留空或 0.0.0.0/0。"
    }
  }
}

resource "huaweicloud_networking_secgroup_rule" "bastion_egress" {
  count = var.enable_bastion ? 1 : 0

  security_group_id = huaweicloud_networking_secgroup.bastion[0].id
  direction         = "egress"
  ethertype         = "IPv4"
  description       = "Allow all egress"
}

# ---------------------------------------------------------------------------
# APIG 专享版实例
#
# 专享版实例部署在 VPC 子网内并导出内网入口地址，可直接作为 ELB 后端。
# ---------------------------------------------------------------------------

resource "huaweicloud_apig_instance" "this" {
  name        = "${local.name}-apig"
  edition     = var.apig_edition
  description = "Private API gateway, no public ingress"

  vpc_id             = huaweicloud_vpc.this.id
  subnet_id          = huaweicloud_vpc_subnet.a.id
  security_group_id  = huaweicloud_networking_secgroup.apig.id
  availability_zones = local.azs

  # 刻意不设置 eip_id —— 不绑公网入口就是「私有 API 网关」在华为云的实现方式。
  # apig_bind_eip 只作为一道显式闸门存在，见下方 precondition。

  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
  tags                  = local.common_tags

  # 专享版实例创建通常需要 20–30 分钟，删除也要数分钟。
  timeouts {
    create = "60m"
    update = "30m"
    delete = "40m"
  }

  lifecycle {
    precondition {
      condition     = var.apig_bind_eip == false
      error_message = <<-EOT
        apig_bind_eip = true 会给 API 网关开公网入口，直接推翻本实践的核心架构意图
        （API 网关零公网入口，唯一入口是内网 ELB）。
        如果确实需要公网暴露，请改为给 ELB 绑 EIP，而不是给网关绑。
      EOT
    }
  }
}

# 分组：承载 API 路由的 API 分组。
resource "huaweicloud_apig_group" "this" {
  instance_id = huaweicloud_apig_instance.this.id
  name        = replace("${local.name}_group", "-", "_")
  description = "Group for the mock hello API"

  force_destroy = true
}

# 读回分组的调试域名（sl_domain）。这个值不是资源的 computed 属性，
# 必须回查；它是 Host 路由的唯一依据。
data "huaweicloud_apig_groups" "this" {
  instance_id = huaweicloud_apig_instance.this.id
  group_id    = huaweicloud_apig_group.this.id
}

# MOCK API：使用 API 网关的 MOCK 后端返回固定响应。
resource "huaweicloud_apig_api" "hello" {
  instance_id = huaweicloud_apig_instance.this.id
  group_id    = huaweicloud_apig_group.this.id
  name        = var.api_name
  type        = "Public"

  request_protocol = "BOTH"
  request_method   = "GET"
  request_path     = var.api_request_path
  matching         = "Exact"

  # 本 API 不启用鉴权。
  security_authentication = "NONE"

  mock {
    status_code = 200
    response    = var.api_mock_response
  }
}

# 固定使用默认 RELEASE 环境，避免调用方额外带 X-Stage 头。
data "huaweicloud_apig_environments" "release" {
  instance_id = huaweicloud_apig_instance.this.id
  name        = "RELEASE"
}

resource "huaweicloud_apig_api_publishment" "this" {
  instance_id = huaweicloud_apig_instance.this.id
  api_id      = huaweicloud_apig_api.hello.id
  env_id      = data.huaweicloud_apig_environments.release.environments[0].id

  lifecycle {
    precondition {
      condition     = length(data.huaweicloud_apig_environments.release.environments) == 1
      error_message = "未在实例上找到唯一的 RELEASE 环境，请先确认实例创建是否完整。"
    }
  }
}

# ---------------------------------------------------------------------------
# 自签名证书（使用者无域名、无证书）
# ---------------------------------------------------------------------------

resource "tls_private_key" "elb" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "elb" {
  private_key_pem = tls_private_key.elb.private_key_pem

  subject {
    common_name  = var.tls_common_name
    organization = "private-apigw-practice"
  }

  dns_names             = [var.tls_common_name]
  validity_period_hours = var.tls_validity_hours

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "huaweicloud_elb_certificate" "this" {
  name        = "${local.name}-cert"
  type        = "server"
  description = "Self-signed cert, replace with a CA-issued one in production"
  certificate = tls_self_signed_cert.elb.cert_pem
  private_key = tls_private_key.elb.private_key_pem
}

# ---------------------------------------------------------------------------
# 独享型 ELB（内网 L7 入口）
# ---------------------------------------------------------------------------

# 规格必须按名称精确取。绝不写 data.huaweicloud_elb_flavors.l7.ids[N]：
# 该数据源按 flavor UUID 字典序返回，下标与规格大小没有关系，
# 随机命中大规格会导致资源规格与预期不符。
data "huaweicloud_elb_flavors" "l7" {
  type = var.elb_flavor_type
  name = var.elb_flavor_name
}

resource "huaweicloud_elb_loadbalancer" "this" {
  name        = "${local.name}-elb"
  description = "Internal L7 entry point for the private API gateway"

  # 只挂内网子网、不绑 EIP，作为纯内网入口。
  ipv4_subnet_id = huaweicloud_vpc_subnet.a.ipv4_subnet_id

  # 可用区数量会影响独享型 ELB 的规格选型，默认单可用区。
  availability_zone = local.azs

  # 按 flavor 名称精确过滤，候选集唯一，规格确定
  l7_flavor_id = data.huaweicloud_elb_flavors.l7.ids[0]

  # 固定开启 IP 型后端（cross_vpc_backend=true）：成员用纯 IP 注册（subnet_id=null），
  # 与 APIG 同 VPC 仍可达；此模式下一旦填 subnet_id 会触发 ELB.8902 并永久 OFFLINE。
  cross_vpc_backend = true

  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
  tags                  = local.common_tags

  lifecycle {
    # 兜住上面那个下标：名称过滤必须刚好命中一个规格，否则 ids[0] 又变成
    # "碰运气"，而规格直接决定资源能力。
    precondition {
      condition     = length(data.huaweicloud_elb_flavors.l7.ids) == 1
      error_message = <<-EOT
        elb_flavor_type / elb_flavor_name 在本区域命中的规格数不等于 1。
        规格目录随区域略有差异，请先实查再指定：
          terraform console
          > data.huaweicloud_elb_flavors.l7
      EOT
    }
  }
}

# 访问控制：独享型 ELB 没有安全组，来源收敛靠监听器绑定 IP 地址组，
# 用于限制可访问监听器的来源网段。
resource "huaweicloud_elb_ipgroup" "this" {
  count = local.enable_ip_group ? 1 : 0

  name        = "${local.name}-ipgroup"
  description = "Allowed source CIDRs for the internal listener"

  dynamic "ip_list" {
    for_each = var.elb_allowed_cidrs
    content {
      ip = ip_list.value
    }
  }
}

# 后端服务器组。留空 type 为兼容模式，配合 cross_vpc_backend=true 的纯 IP 注册
# （member subnet_id=null），健康检查用 TCP/80 探 APIG 内网入口。
resource "huaweicloud_elb_pool" "apig" {
  name            = "${local.name}-pool"
  loadbalancer_id = huaweicloud_elb_loadbalancer.this.id
  protocol        = var.apig_backend_protocol
  lb_method       = "ROUND_ROBIN"
  description     = "Points at the APIG dedicated instance private ingress"
}

# 健康检查用 TCP 探 80：只验证 APIG 内网入口端口在监听，不依赖 Host 路由，
# 因此不受「HTTPS 需绑证书」「HTTP 健康检查 Host 头未被采纳」等坑影响。
# 真正的 200 由调用方 curl（带 -k 与 Host 头）端到端验证；ELB 监听器已开启
# forward_host，会把客户端 Host 透传给 APIG 完成分组路由。
resource "huaweicloud_elb_monitor" "apig" {
  pool_id     = huaweicloud_elb_pool.apig.id
  name        = "${local.name}-hc"
  protocol    = "TCP"
  interval    = 10
  timeout     = 5
  max_retries = 3

  depends_on = [huaweicloud_apig_api_publishment.this]
}

resource "huaweicloud_elb_member" "apig" {
  pool_id       = huaweicloud_elb_pool.apig.id
  name          = "${local.name}-apig-member"
  address       = huaweicloud_apig_instance.this.vpc_ingress_address
  protocol_port = local.apig_backend_port

  # cross_vpc_backend 已固定为 true（IP 型注册），此模式下 subnet_id 必须留空：
  # 一旦填了子网 ID 会触发 ELB.8902，且后端健康检查会永久 OFFLINE。
  # 后端 IP（APIG 内网入口）与 ELB 同处一个 VPC，IP 型注册同样可达。
  subnet_id = null
}

resource "huaweicloud_elb_listener" "https" {
  name            = "${local.name}-listener"
  loadbalancer_id = huaweicloud_elb_loadbalancer.this.id
  protocol        = "HTTPS"
  protocol_port   = 443

  server_certificate = huaweicloud_elb_certificate.this.id
  default_pool_id    = huaweicloud_elb_pool.apig.id

  # 把客户端原始 Host 透传给后端 —— APIG 的分组路由完全依赖它。
  forward_host = true

  access_policy   = local.enable_ip_group ? "white" : null
  ip_group        = local.enable_ip_group ? huaweicloud_elb_ipgroup.this[0].id : null
  ip_group_enable = local.enable_ip_group
}

# ---------------------------------------------------------------------------
# 跳板机（验证入口）
#
# ELB 为纯内网，从 VPC 内发起验证。
# ---------------------------------------------------------------------------

# architecture 必须显式指定。同名镜像同时存在 x86 与 ARM 两版，
# 不过滤会按 most_recent 随机命中 ARM，而 s6.small.1 是 x86 规格，
# 镜像与规格架构不匹配时 ECS 会在创建阶段直接失败。
data "huaweicloud_images_image" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name_regex   = var.bastion_image_name_regex
  architecture = var.bastion_image_architecture
  visibility   = "public"
  most_recent  = true
}

# 规格自检：只用来校验 bastion_flavor_id 在目标可用区确实可售，
# 绝不从这里取下标当规格用（下标与规格大小无关）。
data "huaweicloud_compute_flavors" "bastion_check" {
  count = var.enable_bastion ? 1 : 0

  availability_zone = local.azs[0]
  performance_type  = "normal"
  cpu_core_count    = 1
  memory_size       = 1
}

resource "random_password" "bastion" {
  count = var.enable_bastion ? 1 : 0

  length           = 20
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!@$%^*_+-="
}

resource "huaweicloud_vpc_eip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name = "${local.name}-bastion-eip"

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = "${local.name}-bastion-bw"
    share_type  = "PER"
    size        = var.bastion_eip_bandwidth_mbit
    charge_mode = "traffic"
  }

  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
  tags                  = local.common_tags
}

resource "huaweicloud_compute_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name              = "${local.name}-bastion"
  image_id          = data.huaweicloud_images_image.bastion[0].id
  flavor_id         = var.bastion_flavor_id
  availability_zone = local.azs[0]
  admin_pass        = random_password.bastion[0].result

  security_group_ids = [huaweicloud_networking_secgroup.bastion[0].id]

  network {
    uuid = huaweicloud_vpc_subnet.a.id
  }

  eip_id = huaweicloud_vpc_eip.bastion[0].id

  system_disk_type = "SAS"
  system_disk_size = 40

  enterprise_project_id = var.enterprise_project_id != "" ? var.enterprise_project_id : null
  tags                  = local.common_tags

  lifecycle {
    precondition {
      condition = contains(
        data.huaweicloud_compute_flavors.bastion_check[0].ids,
        var.bastion_flavor_id
      )
      error_message = <<-EOT
        bastion_flavor_id 在目标可用区不可售。可售的 1 vCPU / 1 GiB 规格见：
          terraform console
          > data.huaweicloud_compute_flavors.bastion_check[0].ids
      EOT
    }
  }
}
