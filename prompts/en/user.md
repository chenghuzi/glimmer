Inspect the provided video and audio. Predict whether each canonical behavior feature defined in the system message is observed.

Output exactly one JSON object in this shape:
{"schema_version":"1.0","features":{"B01":false,"B02":false,"B03":false,"B04":false,"B05":false,"B06":false,"B07":false,"B08":false,"B09":false,"B10":true},"overall":"background"}

Rules:
- Use boolean values only.
- Keep feature key order B01, B02, B03, B04, B05, B06, B07, B08, B09, B10.
- Set B10 to true only when none of B01 through B09 are observed; otherwise set B10 to false.
- Set `overall` to `background` when B10 is true; otherwise set it to `behavior_features_observed`.
- Do not add explanations, markdown, confidence values, or text outside the JSON object.
