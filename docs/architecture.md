# 架构说明

## 1. 要解决的问题

某些业务要求 API 网关**绝不暴露公网**，外部调用方只能走一条私网链路进入。本实践给出在华为云上落地该模式的参考实现：

```
调用方（VPC 内 / 经跳板机）
│ HTTPS:443（自签名证书，带 Host 头）
▼
独享型 ELB（L7 / 内网 / 仅内网子网）
│ 后端池 HTTP:80，健康检查 TCP/80
▼
APIG 专享版实例（BASIC / 单 AZ / 无 EIP / vpc_ingress_address）
│
▼
API 分组 → API（MOCK 后端，200 + {"message":"Hello from API GW"}）
```

对外唯一入口是 ELB 的内网 IP；APIG 实例无公网入口。

## 2. 组件与职责

| 组件 | 资源 | 职责 |
|---|---|---|
| 网络底座 | `huaweicloud_vpc` + 两个 `huaweicloud_vpc_subnet` | 提供 ELB 与 APIG 实例所处的私有网络；双子网用于对照与扩展 |
| API 网关 | `huaweicloud_apig_instance`（不设 `eip_id`） | 承载 API 的私网网关，导出 `vpc_ingress_address` 作为内网入口 |
| API 分组与接口 | `huaweicloud_apig_group` + `huaweicloud_apig_api`（mock） | 定义 API 路由与 MOCK 后端；发布到 `RELEASE` 环境 |
| 七层入口 | `huaweicloud_elb_loadbalancer`（L7 / 内网） | 唯一对外入口，终结 HTTPS，按 Host 透传转发 |
| 后端池 | `huaweicloud_elb_pool` + `huaweicloud_elb_member` + `huaweicloud_elb_monitor` | 把请求以 HTTP:80 转发到 APIG 内网入口，健康检查用 TCP/80（只探端口在监听） |
| 证书 | `tls` Provider 自签名 + `huaweicloud_elb_certificate` | 为 ELB 监听器提供 HTTPS 服务端证书 |
| 访问控制 | `huaweicloud_networking_secgroup`（APIG / 跳板机）+ `huaweicloud_elb_ipgroup` | APIG 安全组只放通 VPC 网段；ELB 监听器 IP 地址组白名单 |
| 验证入口 | `huaweicloud_compute_instance` + `huaweicloud_vpc_eip`（跳板机） | VPC 内验证入口，调试后可单独销毁 |

## 3. 关键设计决策

### 3.1 网关天然内网，无需独立私网接入层

APIG 专享版实例创建在用户指定的 VPC 子网内，Terraform 直接导出 `vpc_ingress_address`。把它作为 ELB 的后端成员即可，不需要再建一层独立的私网接入资源。

### 3.2 Host 头路由是链路正确性的核心

APIG 靠 `Host` 头把请求路由到对应 API 分组。因此，**真实流量（客户端→ELB→APIG）** 必须：

- ELB 监听器设置 `forward_host = true`，把客户端原始 Host 透传给后端；
- 调用方必须带 `Host: <分组调试域名>`（API 分组调试域名 `sl_domain` 是唯一可用的 Host）。

> 注意：健康检查**不**走 Host 路由。本实践健康检查用 **TCP/80** 只验证 APIG 内网入口端口在监听（APIG 443 在无证书时不监听、仅 80 开放；且监控协议不按 `domain_name` 设 Host 头），从而避开证书与 Host 头未被采纳的坑；真正的 200 由调用方 `curl -k -H Host` 端到端验证。

### 3.3 访问控制的位置变化

独享型 ELB 没有安全组概念，来源收敛靠监听器级 IP 地址组白名单（`huaweicloud_elb_ipgroup` + `listener.ip_group` / `ip_group_enable`）。反向（ELB → APIG）的收敛仍由 APIG 实例安全组承担，只放通 VPC 网段。

### 3.4 后端固定走 IP 型注册

- `huaweicloud_elb_loadbalancer.this.cross_vpc_backend` 固定为 `true`，后端成员用**纯 IP 注册**（`subnet_id` 留空），`huaweicloud_apig_instance.this.vpc_ingress_address` 即后端地址、`local.apig_backend_port`（HTTP → 80）即回源端口。
- **关键约束**：`cross_vpc_backend=true` 时一旦给成员填 `subnet_id` 会触发 `ELB.8902` 且健康检查永久 `OFFLINE`。本实践已把成员硬编码为 `subnet_id = null`，APIG 与 ELB 同处一个 VPC，纯 IP 注册仍可达。

### 3.5 规格写死、可复现

ELB 规格按名称精确锁定（`L7_flavor.elb.s1.small`，10 LCU），并用 `lifecycle` precondition 校验候选集唯一，禁止数据源下标随机选型，确保规格可复现。可用区数量（`availability_zone`）会影响规格选型，默认单 AZ。

### 3.6 自签名证书仅用于打通链路

本实践无域名、无证书，HTTPS 用 `tls` Provider 生成自签名证书，客户端须 `curl -k`。**生产环境必须替换为可信 CA 证书**，并酌情绑定已备案的独立域名。

## 4. 数据流

1. 调用方在 VPC 内（或经跳板机）向 ELB 内网 IP 的 `https://<ELB_IP>/hello` 发起请求，带 `Host: <分组调试域名>`。
2. ELB 监听器（HTTPS:443）用证书终结 TLS，透传原始 Host，按后端池以 **HTTP:80** 转发到 APIG 内网入口 `vpc_ingress_address:80`（APIG 443 须绑证书才监听，本实践仅开放 80）。
3. APIG 依据 Host 头路由到对应分组下的 `/hello` API，命中 MOCK 后端，返回 200 + 固定响应体。
4. 响应原路返回调用方。

## 5. 资源组成

- **常驻资源**：APIG 专享版 BASIC、独享型 ELB 固定规格、跳板机 ECS。
- **按量资源**：跳板机 EIP。
- **免费资源**：VPC / 子网 / 安全组 / IP 地址组 / 证书。
