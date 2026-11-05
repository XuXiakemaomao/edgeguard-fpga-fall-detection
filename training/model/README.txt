文件夹说明

这里保存训练得到的模型、数据集压缩包、训练历史和恢复信息。checkpoint.npz 是导出 FPGA 权重时使用的源模型。

本目录中的文件：
checkpoint.npz：最终模型权重。
checkpoint_best.npz：验证集表现最好的模型快照。
checkpoint_restored.json：模型恢复信息。
dataset.npz：模型或数据集压缩文件。
train_history.json：训练过程记录。
