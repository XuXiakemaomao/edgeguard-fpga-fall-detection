# 系统架构

```text
HDMI 720p@60fps
  -> ADV7611 video decoding
  -> RGB-to-grayscale
  -> 2x2 downsampling to 640x360
  -> adaptive background and motion mask
  -> 3x3 neighborhood cleanup
  -> block-level region merging
  -> multi-target tracking and primary-target selection
  -> 48x48 ROI crop
  -> INT8 CNN: normal / fall / other
  -> temporal confirmation and evidence gating
  -> HDMI overlay and red alert
```

## 主要模块

- `preprocess/`：灰度化、2×2 下采样、背景建模、掩码清理和输入监视。
- `motion_tracking/`：块级判决、区域合并、目标跟踪、行为状态和评分叠加。
- `cnn_alarm/`：ROI 裁剪、CNN 调度、INT8 网络、平滑、门控、告警保持和显示叠加。
- `top_video/`：HDMI 接收、I2C 配置、像素时钟、TMDS 输出和顶层集成。

## 数据流原则

系统先以低开销运动分析找出目标，再将固定 48×48 主目标区域送入 CNN。该结构避免整帧 CNN
计算，同时保持网络输入尺寸固定。
