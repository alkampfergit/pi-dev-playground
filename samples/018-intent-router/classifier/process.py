"""Persistent JSON-lines bridge to local GLiNER2 or Jeff inference."""
import json
import sys
import time


def main() -> None:
    jeff_client = None
    jeff_function = None
    jeff_key = None
    gliner_classifier = None
    gliner_key = None
    gliner_schema = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            config = request["config"]
            engine = config["engine"]
            start = time.perf_counter()
            if engine == "gliner2":
                key = json.dumps({"modelPath": config["modelPath"], "labels": config["labels"]}, sort_keys=True)
                if gliner_classifier is None or gliner_key != key:
                    import os
                    os.environ["HF_HUB_OFFLINE"] = "1"
                    from gliner2 import AutoExtractor

                    # The model has already been downloaded by setup-local-classifier.sh.
                    # Offline flags plus local_files_only ensure inference cannot reach a Hub.
                    gliner_classifier = AutoExtractor.from_pretrained(config["modelPath"],
                                                                      local_files_only=True,
                                                                      map_location="cpu")
                    labels = config["labels"]
                    gliner_schema = gliner_classifier.create_schema().classification(
                        "intent", [labels["code"], labels["general"]],
                        multi_label=False, cls_threshold=0.0)
                    gliner_key = key
                inputs = request["input"]
                context = inputs.get("previousUserTurns", [])
                parts = [f"Previous user task context: {turn}" for turn in context[-3:]]
                parts.append(f"Current user request: {inputs['latest']}")
                if inputs.get("lastIntent"):
                    parts.append(f"The preceding request was classified as: {inputs['lastIntent']}.")
                text = "\n".join(parts)[:6000]
                predictions = gliner_classifier.extract(text, gliner_schema, include_confidence=True)
                classification = predictions.get("intent", {})
                label = classification.get("label") if isinstance(classification, dict) else classification
                confidence = classification.get("confidence") if isinstance(classification, dict) else None
                labels = config["labels"]
                label_to_intent = {labels["code"]: "code", labels["general"]: "general"}
                if label not in label_to_intent or not isinstance(confidence, (int, float)):
                    raise ValueError("GLiNER2 returned no recognized intent label")
                intent = label_to_intent[label]
                confidence = float(confidence)
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
