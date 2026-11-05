# CNN 权重文件说明

本目录保存 8 位整数 CNN 的权重、偏置、量化表和校验信息。

RTL 通过相对路径 `$readmemh("../../../weights/*.mem", ...)` 加载这些文件。
Vivado 2023.1 会相对于 HDL 文件所在目录解析该路径，而不是相对于工程根目录
或综合运行目录解析。综合时必需的文件包括：

```text
qin.mem
w1.mem
w2.mem
w3.mem
w4.mem
b1.mem
b2.mem
b3.mem
b4.mem
```

另外保留：

```text
mult.mem
shift.mem
manifest.json
SHA256SUMS.txt
```

在 Vivado 图形界面中，可以把全部 `.mem` 文件加入 Design Sources 便于查看，
但更关键的是保持 `src/rtl/cnn_alarm/` 与根目录 `weights/` 的相对位置不变。
日志中的 `$readmem data file ... is read successfully` 表示加载成功。

不要依赖手动复制到 `project.runs/synth_1`。如果移动 RTL 或权重目录，必须
重新计算 `$readmemh` 的相对路径。使用本目录中的 `SHA256SUMS.txt` 可以检查
文件是否被意外替换。
