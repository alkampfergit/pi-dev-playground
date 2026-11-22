"""Create deterministic family-separated train/dev/calibration JSONL files."""
import json
from collections import defaultdict
from pathlib import Path

source = Path(__file__).with_name("examples.jsonl")
rows = [json.loads(line) for line in source.read_text().splitlines() if line.strip()]
families = defaultdict(list)
for row in rows:
    families[row["family"]].append(row)
names = sorted(families)
train_families = set(names[::2])
dev_families = set(names[1::4])
calibration_families = set(names[3::4])
if train_families & dev_families or train_families & calibration_families or dev_families & calibration_families:
    raise SystemExit("family split overlap")
for filename, selected in (("train.jsonl", train_families), ("dev.jsonl", dev_families), ("calibration.jsonl", calibration_families)):
    output = Path(__file__).with_name(filename)
    output.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for name in names if name in selected for row in families[name]))
    print(f"{filename}: {sum(len(families[name]) for name in selected)} rows, {len(selected)} families")
