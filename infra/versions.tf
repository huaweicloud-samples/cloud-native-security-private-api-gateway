terraform {
  # precondition / lifecycle 块用于把规格自检提前到 plan 阶段，需要 1.4+。
  required_version = ">= 1.4.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.90.0"
    }
    # 无域名、无证书场景下用自签名证书打通端到端 HTTPS。
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# 认证信息
#
# 认证信息一律通过环境变量提供，绝不写入 .tf / .tfvars / 版本库：
#   export HW_ACCESS_KEY=<AK>
#   export HW_SECRET_KEY=<SK>
#   export HW_REGION_NAME=<region>
# ---------------------------------------------------------------------------
provider "huaweicloud" {
  region = var.region
}

resource "random_id" "suffix" {
  byte_length = 3
}
