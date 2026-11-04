# 验证结果

## 综合与实现

- Synth errors：0
- Synth critical warnings：0
- Implementation errors：0
- Implementation critical warnings：0
- Bitstream generation：success
- DRC errors：0

## 时序

- WNS：+0.099 ns
- WHS：+0.056 ns
- Failing endpoints：0 / 91,716

## 资源与功耗

- LUT：33,006 / 133,800（24.67%）
- Register：14,834 / 269,200（5.51%）
- Block RAM Tile：132.5 / 365（36.30%）
- DSP：20 / 740（2.70%）
- Power estimate：0.582 W

## CNN

1,142 个测试样本上：

- INT8 accuracy：81.96%
- Fall recall：90.96%
- Fall precision：79.17%
- FP32/INT8 top-1 agreement：92.99%

## 板级测试

- 三段真实摔倒全部检出
- 两次误报
- 召回率：1.00
- 精确率：0.60

板级样本数量有限，不作为所有走廊场景下的通用性能保证。
