# Laya evaluation fixtures

Test-only fixtures for the old apps' Laya tests (`legacy/ios/Tests/LayaEvaluationTests.swift`, skipped by default). No weights are included in the app or committed to Git; without a local `Laya/` folder of the pinned model, the evaluation skips, and a skip is not a successful model check.

- `laya-heldout.json`: the held-out calibration and test cases `LayaEvaluationTests` runs on the Mac and in the Simulator.
- `laya-golden.json`: a parity fixture comparing the upstream Python Core ML implementation with the Swift tokenizer and runtime on the same state. Its expected answer is deliberately a confident scheduling mistake: passing proves numerical agreement on that fixture, not decision quality.

The scripts that made these fixtures and download the pinned model for the tests are kept with the research, outside this repository.
