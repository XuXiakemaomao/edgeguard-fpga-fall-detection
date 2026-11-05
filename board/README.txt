上板说明

本仓库不直接提交 Vivado 生成的比特流，避免把可重新生成的二进制文件混入源码历史。最终构建生成的比特流文件名为 hdmi_wrapper.bit，SHA256 为：
8654D9CF502ADCB0A68116101BD5BC53649135983E9028AA5BFFCA84E5999E8

重新生成时运行仓库根目录下的 build/run_vivado_timing.tcl，目标器件为 xc7a200tfbg484-2。最终时序报告位于 build/reference_reports，WNS 为 +0.099 ns，WHS 为 +0.056 ns，失败端点为 0。

板级输入为 1280×720、60 fps HDMI。输出为 HDMI 原始画面和红色疑似摔倒告警框。运行不依赖电脑、网络或串口。