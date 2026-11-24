"""Download the demo model once and package all inference assets locally."""
from pathlib import Path
import os

ROOT = Path(__file__).resolve().parents[1]
MODEL_ID = "fastino/gliner2.5-base-v1"
REVISION = "07d99c0ba5d15cb3b24e0a236fa99bdd4ef87a5c"
DESTINATION = ROOT / "models" / "gliner2.5-base-v1"
REQUIRED_FILES = ("config.json", "model.safetensors", "tokenizer.json")
os.environ.setdefault("HF_HOME", str(ROOT / ".hf-home"))
os.environ.setdefault("HF_HUB_CACHE", str(ROOT / ".hf-home" / "hub"))

if all((DESTINATION / name).is_file() for name in REQUIRED_FILES):
    print(f"Local model already exists: {DESTINATION}")
elif DESTINATION.exists():
    raise SystemExit(f"Local model directory is incomplete: {DESTINATION}. Remove it and rerun setup.")
else:
    from gliner2 import AutoExtractor

    print(f"Downloading {MODEL_ID} at revision {REVISION}; this is a large local model download.", flush=True)
    model = AutoExtractor.from_pretrained(MODEL_ID, revision=REVISION, cache_dir=str(ROOT / ".hf-home" / "hub"),
                                          map_location="cpu")
    DESTINATION.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(DESTINATION), safe_serialization=True)
    print(f"Saved complete offline model to {DESTINATION}")
