# Commits Log

Purpose:
- Keep a human-readable summary of commits and why they matter for experiments.

## Entry template
- Date:
- Commit:
- Scope:
- Why:
- Metrics/threshold impact:
- Datasets impacted:
- Follow-up:

## 2026-03-24 12:48 (UTC)
- Date: 2026-03-24
- Commit: d851026
- Scope: FlowMatching/SPADEJvM config updates, including AdaLN and LabelConditioner support.
- Why: Add a simpler global label-conditioning route via AdaLN while preserving the original spatial conditioning path for fair ablations.
- Metrics/threshold impact: No metric or threshold convention changed; validation kept the existing OpenSTL metric stack and `metric_threshold` handling.
- Datasets impacted: MMNIST and MMNIST_CIFAR.
- Follow-up: Compare AdaLN vs SPADE under matched x-pred/v-loss settings and identical evaluation scripts.
