# 小鸡别太闲

一个面向 VPS / 小鸡的轻量 CLI 工具箱，用来把常见的网络质量、性能测试和定期巡检任务整理成一个交互式菜单。

## 使用方法

### 中文版：国外服务器使用

```bash
curl -fsSL https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

### 中文版：国内服务器使用

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

### 英文版：国外服务器使用

```bash
curl -fsSL https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2english.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

## 项目简介

**小鸡别太闲** 是一个偏“懒人化”的服务器巡检脚本，主要用于定期运行 VPS 常用测试脚本，并保存关键结果，方便后续回看。

目前包含：

- 定期 Ping 监控
- 定期测 IP 质量
- 定期 YABS 测试
- 定期 Bench.sh 测试
- 定期 NodeQuality 检测
- 首次开启引导

脚本通过 CLI 菜单交互，不需要记复杂命令，适合在 VPS 上直接运行。

## CLI 交互布局预览

主菜单大致如下：

```text
╔══════════════════════════════╗
║          小鸡别太闲          ║
╚══════════════════════════════╝
1) 开启引导
2) 定期 Ping 监控
3) 定期测 IP 质量（默认每天 03:00 ±30分钟）
4) 定期 YABS 测试（默认每天 04:00 ±30分钟）
5) 定期 Bench.sh 测试（默认每天 05:00 ±30分钟）
6) 定期 NodeQuality 检测（默认每 7 天 06:00 ±30分钟 + 同日 22:00 ±30分钟）
0) 退出
```

其中 `±30分钟` 表示脚本会在目标时间前后 30 分钟内随机执行，避免所有机器在同一时刻集中跑测试。

## 开启引导

首次使用可以选择：

```text
1) 开启引导
```

引导支持两种方式：

```text
直接回车：默认开启「定期测 IP 质量」和「定期 YABS 测试」
输入 1：逐个功能单独引导，1 开启，2 不开启
输入 2：取消引导
```

默认开启时，会提醒其余功能需要手动开启：

- 定期 Ping 监控
- 定期 Bench.sh 测试
- 定期 NodeQuality 检测

## 功能说明

### 1. 定期 Ping 监控

用于持续监控指定目标的连通性。

菜单示例：

```text
1) 查看结果
2) 添加目标
3) 设置 (间隔/保留/备注)
4) 开启监控
5) 关闭监控
0) 返回主菜单
```

### 2. 定期测 IP 质量

默认每天：

```text
03:00 ±30分钟
```

子菜单：

```text
1) 查看结果
2) 开启定时（默认每天 03:00 ±30分钟）
3) 立即测试一次
4) 设置
5) 关闭定时
0) 返回主菜单
```

### 3. 定期 YABS 测试

默认每天：

```text
04:00 ±30分钟
```

开启定时或立即测试前，会检查内存是否达到 1024MB。

如果物理内存不足，例如只有约 500MB，会自动补足专用 swap：

```text
/swapfile.sshtool-yabs
```

子菜单：

```text
1) 查看结果
2) 开启定时（默认每天 04:00 ±30分钟）
3) 立即测试一次
4) 设置
5) 关闭定时
0) 返回主菜单
```

### 4. 定期 Bench.sh 测试

默认每天：

```text
05:00 ±30分钟
```

子菜单：

```text
1) 查看结果
2) 开启定时（默认每天 05:00 ±30分钟）
3) 立即测试一次
4) 设置
5) 关闭定时
0) 返回主菜单
```

### 5. 定期 NodeQuality 检测

默认每 7 天循环一次，从开启当天开始计算。

同一天会测试两轮：

```text
06:00 ±30分钟
22:00 ±30分钟
```

NodeQuality 执行命令：

```bash
printf 'v\ny\ny\ny\n' | bash <(curl -sL https://run.NodeQuality.com)
```

脚本不会保存完整的大段输出，只会提取并保存最终结果链接，例如：

```text
https://nodequality.com/r/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

子菜单：

```text
1) 查看结果
2) 开启定时（默认每 7 天 06:00 ±30分钟 + 同日 22:00 ±30分钟）
3) 立即测试一次
4) 设置
5) 关闭定时
0) 返回主菜单
```

## 设置方式

设置菜单尽量只要求输入数字，不需要输入英文或符号。

例如想把时间改成凌晨 3 点整：

```text
小时输入：3
分钟输入：0
```

不要输入：

```text
03:00
```

因为测试时间带有 `±30分钟`，所以设置为 `03:00` 后，实际运行窗口是：

```text
02:30 - 03:30
```

NodeQuality 的间隔天数也只需要输入数字，例如：

```text
7
```

表示每 7 天循环测试一次。

## 说明

本项目更偏向个人 VPS 巡检和结果留档用途。测试脚本可能会产生一定网络流量和 CPU / 磁盘压力，建议根据自己的服务器配置和流量额度合理开启。

---

# Keep Your VPS Busy

A lightweight CLI toolbox for VPS servers. It turns common network quality checks, benchmark scripts, and scheduled inspection tasks into a simple interactive menu.

## Usage

### Chinese version: for overseas servers

```bash
curl -fsSL https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

### Chinese version: for mainland China servers

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

### English version: for overseas servers

```bash
curl -fsSL https://raw.githubusercontent.com/cyt298t/hahaaa/main/haha2english.sh -o sshtool.sh && chmod +x sshtool.sh && ./sshtool.sh
```

## Introduction

**Keep Your VPS Busy** is a lazy-friendly VPS inspection script. It helps you run common VPS test scripts on a schedule and keeps the important results for later review.

Current features:

- Scheduled Ping Monitor
- Scheduled IP Quality Test
- Scheduled YABS Test
- Scheduled Bench.sh Test
- Scheduled NodeQuality Test
- First-time Setup Wizard

Everything is managed through an interactive CLI menu, so you do not need to remember long commands.

## CLI Layout Preview

The main menu looks roughly like this:

```text
╔══════════════════════════════╗
║       Keep Your VPS Busy     ║
╚══════════════════════════════╝
1) Setup Wizard
2) Scheduled Ping Monitor
3) Scheduled IP Quality Test (default daily 03:00 +/-30 minutes)
4) Scheduled YABS Test (default daily 04:00 +/-30 minutes)
5) Scheduled Bench.sh Test (default daily 05:00 +/-30 minutes)
6) Scheduled NodeQuality Test (default every 7 days 06:00 +/-30 minutes + same day 22:00 +/-30 minutes)
0) Exit
```

`+/-30 minutes` means the task will run randomly within 30 minutes before or after the target time. This helps avoid running tests on many servers at exactly the same moment.

## Setup Wizard

For first-time setup, choose:

```text
1) Setup Wizard
```

The wizard supports two modes:

```text
Press Enter: enable Scheduled IP Quality Test and Scheduled YABS Test by default
Enter 1: guide each feature one by one, 1 = enable, 2 = skip
Enter 2: cancel the wizard
```

When using the default mode, the script will also remind you that the following features need to be enabled manually if needed:

- Scheduled Ping Monitor
- Scheduled Bench.sh Test
- Scheduled NodeQuality Test

## Features

### 1. Scheduled Ping Monitor

Continuously monitors the reachability of specified targets.

Menu example:

```text
1) View Results
2) Add Target
3) Settings (interval/retention/note)
4) Enable Monitoring
5) Disable Monitoring
0) Back to Main Menu
```

### 2. Scheduled IP Quality Test

Default schedule:

```text
03:00 +/-30 minutes daily
```

Submenu:

```text
1) View Results
2) Enable Schedule (default daily 03:00 +/-30 minutes)
3) Run Once Now
4) Settings
5) Disable Schedule
0) Back to Main Menu
```

### 3. Scheduled YABS Test

Default schedule:

```text
04:00 +/-30 minutes daily
```

Before enabling the schedule or running once manually, the script checks whether physical memory reaches 1024MB.

If physical memory is not enough, for example around 500MB, it automatically creates a dedicated swap file to fill the gap:

```text
/swapfile.sshtool-yabs
```

Submenu:

```text
1) View Results
2) Enable Schedule (default daily 04:00 +/-30 minutes)
3) Run Once Now
4) Settings
5) Disable Schedule
0) Back to Main Menu
```

### 4. Scheduled Bench.sh Test

Default schedule:

```text
05:00 +/-30 minutes daily
```

Submenu:

```text
1) View Results
2) Enable Schedule (default daily 05:00 +/-30 minutes)
3) Run Once Now
4) Settings
5) Disable Schedule
0) Back to Main Menu
```

### 5. Scheduled NodeQuality Test

By default, it runs every 7 days, starting from the day you enable it.

On each test day, it runs twice:

```text
06:00 +/-30 minutes
22:00 +/-30 minutes
```

NodeQuality command:

```bash
printf 'v\ny\ny\ny\n' | bash <(curl -sL https://run.NodeQuality.com)
```

The script does not keep the full long output. It only extracts and saves the final result URL, for example:

```text
https://nodequality.com/r/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Submenu:

```text
1) View Results
2) Enable Schedule (default every 7 days 06:00 +/-30 minutes + same day 22:00 +/-30 minutes)
3) Run Once Now
4) Settings
5) Disable Schedule
0) Back to Main Menu
```

## Settings

Settings are designed to use numbers only. You do not need to enter English words or symbols.

For example, to set the time to 3 AM:

```text
Hour: 3
Minute: 0
```

Do not enter:

```text
03:00
```

Because scheduled tests use `+/-30 minutes`, setting the target time to `03:00` means the actual run window is:

```text
02:30 - 03:30
```

For the NodeQuality interval, just enter a number such as:

```text
7
```

This means the test runs every 7 days.

## Notes

This project is mainly intended for personal VPS inspection and result archiving. Benchmark and network test scripts may consume bandwidth and create CPU / disk load. Please enable them according to your VPS resources and traffic quota.
