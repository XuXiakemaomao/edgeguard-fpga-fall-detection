# Vivado 工程

`edgeguard.xpr` 是最终无串口源码的图形界面工程，包含：

- 44 个 RTL 文件；
- 1 个 XDC 约束文件；
- 11 个 `.mem` 权重文件；
- 顶层 `hdmi_wrapper`；
- 器件 `xc7a200tfbg484-2`。

XPR 中的资源路径相对于自身目录保存，因此移动时应整体移动仓库根目录，
不要只移动 XPR。

首次打开后 Vivado 会重新生成缓存目录。正式构建仍建议使用上一级目录中的
`build/run_vivado_timing.tcl`，以自动生成完整报告和比特流。
