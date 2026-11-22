"""Download the demo model once and package all inference assets locally."""
from pathlib import Path
import os

ROOT = Path(__file__).resolve().parents[1]
MODEL_ID = "knowledgator/gliner-multitask-large-v0.5"
DESTINATION = ROOT / "models" / "gliner-multitask-large-v0.5"
os.environ.setdefault("HF_HOME", str(ROOT / ".hf-home"))
os.environ.setdefault("HF_HUB_CACHE", str(ROOT / ".hf-home" / "hub"))

if (DESTINATION / "gliner_config.json").exists():
    print(f"Local model already exists: {DESTINATION}")
else:
    from gliner import GLiNER

    print(f"Downloading {MODEL_ID}; this is a large local model download.", flush=True)
    model = GLiNER.from_pretrained(MODEL_ID, cache_dir=str(ROOT / ".hf-home" / "hub"),
                                   map_location="cpu", dtype="float16", variant="fp16")
    DESTINATION.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(DESTINATION), safe_serialization=True)
    print(f"Saved complete offline model to {DESTINATION}")
