"""Persistent JSON-lines bridge to local GLiNER or Jeff inference."""
import json
import sys
import time


def main() -> None:
    jeff_client = None
    jeff_function = None
    jeff_key = None
    gliner_classifier = None
    gliner_key = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            config = request["config"]
            engine = config["engine"]
            start = time.perf_counter()
            if engine == "gliner":
                key = json.dumps({"modelPath": config["modelPath"], "labels": config["labels"]}, sort_keys=True)
                if gliner_classifier is None or gliner_key != key:
                    from gliner import GLiNER
                    from gliner.multitask import GLiNERClassifier

                    # The model has already been downloaded by setup-local-classifier.ps1.
                    # Offline flags plus local_files_only ensure inference cannot reach a Hub.
                    import os
                    os.environ["HF_HUB_OFFLINE"] = "1"
                    model = GLiNER.from_pretrained(config["modelPath"], local_files_only=True,
                                                   map_location="cpu", dtype="float16")
                    gliner_classifier = GLiNERClassifier(model=model)
                    gliner_key = key
                inputs = request["input"]
                context = inputs.get("previousUserTurns", [])
                parts = [f"Previous user task context: {turn}" for turn in context[-3:]]
                parts.append(f"Current user request: {inputs['latest']}")
                if inputs.get("lastIntent"):
                    parts.append(f"The preceding request was classified as: {inputs['lastIntent']}.")
                text = "\n".join(parts)[:6000]
                labels = config["labels"]
                predictions = gliner_classifier(text, classes=[labels["code"], labels["general"]],
                                                multi_label=True, threshold=0.0)
                candidates = predictions[0] if predictions else []
                label_to_intent = {labels["code"]: "code", labels["general"]: "general"}
                candidates = [item for item in candidates if item.get("label") in label_to_intent and isinstance(item.get("score"), (int, float))]
                if not candidates:
                    raise ValueError("GLiNER returned no recognized intent label")
                best = max(candidates, key=lambda item: item["score"])
                intent = label_to_intent[best["label"]]
                confidence = float(best["score"])
                runner_up = max((float(item["score"]) for item in candidates if item is not best), default=0.0)
                if confidence - runner_up < float(config.get("marginThreshold", 0.0)):
                    confidence = 0.0
            elif engine == "jeff":
                jeff_config = config["jeff"]
                key = json.dumps(jeff_config, sort_keys=True)
                if jeff_client is None:
                    import jeff

                    # Jeff.local is explicitly local: this sample never calls Jeff.remote.
                    jeff_client = jeff.Jeff.local([jeff_config["adapter"]])
                if jeff_function is None or key != jeff_key:
                    jeff_function = jeff_client.function(jeff_config["functionId"],
                        context=jeff_config.get("context", {}), labels=jeff_config.get("labels", {}))
                    jeff_key = key
                value = jeff_function({"latest": request["input"]["latest"],
                    "previous_user_turns": request["input"].get("previousUserTurns", []),
                    "last_intent": request["input"].get("lastIntent")})
                intent = getattr(value, "value", None)
                confidence = getattr(value, "confidence", None)
                abstained = getattr(value, "abstained", False)
                if isinstance(intent, dict):
                    intent = intent.get("intent")
                if abstained:
                    confidence = 0.0
            else:
                raise ValueError("Unknown local classifier engine")
            elapsed = (time.perf_counter() - start) * 1000
            if intent not in ("code", "general") or not isinstance(confidence, (int, float)):
                raise ValueError("Local classifier did not produce a valid intent and score")
            result = {"intent": intent, "confidence": float(confidence), "latencyMs": elapsed}
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        except Exception as error:  # error text may include request data; redact it
            try:
                print(json.dumps({"id": request.get("id"), "error": type(error).__name__}), flush=True)
            except Exception:
                print(json.dumps({"error": "classification failed"}), flush=True)
    close = getattr(jeff_client, "close", None)
    if callable(close):
        close()


if __name__ == "__main__":
    main()
