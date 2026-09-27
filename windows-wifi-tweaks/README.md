# Windows 无线网卡调优脚本

连随身 WiFi 时网速不稳、偶尔突然卡一下，排查下来瓶颈其实在 5G 上行，
但顺手把网卡上几个拖后腿的高级属性也调了。

## 用法

**右键 `fix-wifi.bat` → 以管理员身份运行。**

必须提权 —— `Set-NetAdapterAdvancedProperty` 写的是 HKLM 下的网卡参数，
普通权限会直接报"拒绝访问"。

跑完重启网卡或重启系统生效。结果会写到脚本同目录的 `nic_opt_result.txt`。

## 改了什么

| 高级属性 | 原值 | 改为 | 作用 |
| --- | --- | --- | --- |
| `MIMOPowerSaveMode` | Auto SMPS | No SMPS | 关掉 MIMO 省电，避免省电导致的吞吐抖动 |
| `ThroughputBoosterEnabled` | Disabled | Enabled | 打开吞吐增强 |
| `RoamAggressiveness` | Medium-low | Lowest | 降低漫游积极性，别没事就找别的 AP |
| `RoamingPreferredBandType` | No preference | 5GHz | 优先留在 5GHz |

## 改之前先看清这两件事

1. **网卡名写死是 `WLAN`。** 用 `Get-NetAdapter` 确认你自己的名字，不是的话改
   `nic_opt.ps1` 里的 `-Name 'WLAN'`。
2. **不同驱动支持的 keyword 不一样。** 先跑一遍看看哪些项失败：

   ```powershell
   Get-NetAdapterAdvancedProperty -Name WLAN |
       Select-Object RegistryKeyword, DisplayValue
   ```

   `nic_opt.ps1` 对每一项都做了 try/catch，不支持的会记 `[FAIL]` 并继续，
   不会中途崩掉。

## 怎么改回去

`Set-NetAdapterAdvancedProperty -Name WLAN -RegistryKeyword <key> -RegistryValue <原值>`，
或者直接在设备管理器里把网卡的高级属性改回默认。
