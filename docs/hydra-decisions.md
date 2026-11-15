# Hydra 决策点（实验室）设计（已归档）

状态：已于 2026-11-14 移除。移除前最后代码位于 dev 提交 `07a38dd0f`（Dev 2.5.32）。

## 曾经的设计

在 Alpha（实验室）中运行的影子测试：在 Hydra 2.0 的六个环节（`headReport`、`preReview`、`reviewDisposition`、`continuation`、`reviewFindings`、`followUp`）异步调用 TypeSafe Jev，只记账、不展示给 lead、不改变 Hydra 的任何行为。

## 最终评估（A5S + H8S，3072 条判断，qv2 自 2026-11-02 起）

- **H1 `reworkLikely`**：对 `rework_after` 的 AUROC 为 0.682，但零成本启发式基线“更短的回报”达到 0.701（差值 95% CI：-0.14..0.08）；对 `head_missed_defect` 呈反向（0.42）。阈值 0.7 时精确率 14.9%（基准率 6.5%）。
- **H2 `defectLikely`**：在所有标签上均未超过改动行数基线。
- **H3 `reviewDisposition`**：正则补充识别中文「接受」后，与 Jev 一致率达 95.3%，继续保留正则方案。
- **测量点抽查**：`reviewFindings` 将 87% 的意见归为 `inJobDefect`（抽样本身正确，但信息量很低）；`followUp` 的 `correction` 标签抽样约 9/14 准确，错误集中在低置信度样本；`continuation` 的 `omission` 选项把“先调查再实施”的续派误标为返工。

## 结论

Jev 对已有文本的分类较稳定，但这一能力可被正则或任意低成本模型替代；预测类点位受限于缺少 diff 等上下文信息，而信息最充分的位置本就由 lead 与异家审查承担；将数据外发至非零数据保留（non-ZDR）服务的成本真实存在，因此决定移除。

## 归档数据与本地残留

账本、library 快照、评估产出以及 `07a38dd0f` 版本的脚本与设计文档均保存在仓库外的制品根目录 `private-artifacts/jev-decisions-archive-2026-11-14/`。

用户 Mac 上已有的决策账本文件与钥匙串中的 `TypeSafe API Key` 均保留不动，如需清理可手动删除。
