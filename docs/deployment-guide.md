# 部署指南

> 凭据一律通过环境变量注入，请勿写入文件。

## 0. 准备

- 区域：`cn-south-1`（华南-广州）
- 工具：Terraform `>= 1.4.0`、`huaweicloud` Provider `>= 1.90.0`、`tls` `>= 4.0.0`、`random` `>= 3.5.0`
- 凭据：从凭据文件读取 AK/SK，仅导出到当前 shell 环境变量

```bash
# 凭据仅当前 shell 生效，不写入文件
export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
export HW_SECRET_KEY="<HW_SECRET_KEY>"
export HW_REGION_NAME="cn-south-1"
```

> 文档与代码中一律用占位符 `<HW_ACCESS_KEY>` / `<HW_SECRET_KEY>`；真实值绝不出现。

## 1. 初始化

```bash
cd infra
terraform init
```

预期：拉取 `huaweicloud` / `tls` / `random` Provider，生成 `.terraform.lock.hcl`。

## 2. 预览（可选但推荐）

```bash
terraform plan -out tfplan.bin
```

重点核对：

- `huaweicloud_apig_instance.this` 的 `eip_id` 未设置（保持私有）。
- `huaweicloud_elb_loadbalancer.this.l7_flavor_id` 命中唯一规格 `L7_flavor.elb.s1.small`（precondition 会在不唯一时直接报错）。
- `huaweicloud_compute_instance.bastion` 镜像架构为 `x86`，与 `s6.small.1` 一致。
- `huaweicloud_elb_listener.https.forward_host = true`，且绑定了 `ip_group`（白名单）。

预期资源数：约 26 个（含跳板机 ECS + EIP）。

## 3. 部署

```bash
terraform apply "tfplan.bin"
```

> 若未生成 `tfplan.bin`，直接 `terraform apply` 亦可，但会重新 plan。

APIG 专享版实例创建约 **20–30 分钟**，请耐心等待；ELB 与 ECS 创建较快。完成后 Terraform 会输出各资源地址与验证命令。

## 4. 查看输出

```bash
terraform output
```

关键输出：

| 输出 | 说明 |
|---|---|
| `apig_private_ingress_address` | APIG 内网入口地址（ELB 后端挂的就是它） |
| `api_group_domain` | API 分组调试域名，调用时必须作为 Host 头带入 |
| `elb_private_ip` | 内网 ELB 私网 IP，对外唯一入口 |
| `apig_public_ingress_address` | 应为空；非空即说明网关被误绑 EIP |
| `bastion_public_ip` | 跳板机公网 IP |
| `bastion_password` | 跳板机随机密码（sensitive，用 `terraform output -raw bastion_password` 取） |
| `verify_command` | 在跳板机上执行的端到端验证命令 |
| `negative_check_command` | 直连 APIG 内网入口的验证命令 |

## 5. 验证

登录跳板机（SSH，来源已被安全组限制为你的出口 IP），执行：

```bash
$(terraform output -raw verify_command)
# 等价：
# curl -sS -k -i -H 'Host: <分组调试域名>' https://<ELB 内网 IP>/hello
```

预期：

```
HTTP/1.1 200 OK
...
{"message": "Hello from API GW"}
```

反向验证（证明网关确实内网可达）：

```bash
$(terraform output -raw negative_check_command)
```

也应返回 200。任何公网路径都不应直达网关（因其无 EIP）。

## 6. 清理

```bash
terraform destroy
```

- APIG 实例删除需数分钟，耐心等待。
- `destroy` 完成后，建议到控制台或经 API 直查确认实例已移除。
- 若只想保留网关、回收验证资源，可置 `enable_bastion = false` 后重新 `apply` 再 `destroy` 跳板机。

## 7. 常见调整

| 想做的调整 | 变量 |
|---|---|
| 换区域 | `region` |
| 换网关规格 | `apig_edition`（BASIC/PROFESSIONAL/ENTERPRISE/PLATINUM） |
| 改 API 路径 / 响应 | `api_request_path` / `api_mock_response` |
| 改 ELB 规格 | `elb_flavor_type` / `elb_flavor_name`（务必按名称精确指定） |
| 改来源白名单 | `elb_allowed_cidrs` |
| ELB→APIG 回源协议 | `apig_backend_protocol`（默认 `HTTP`；APIG 443 须绑证书才监听，故默认走 HTTP:80；绑证书后可改 `HTTPS`） |
| 关跳板机 | `enable_bastion = false` |
| 改 SSH 来源 | `bastion_ssh_source_cidr`（必须显式为出口 IP/32） |
