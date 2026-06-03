请检查提供的视频和音频，判断是否观察到系统消息中定义的各个标准行为特征。

请只输出一个符合以下形状的 JSON 对象：
{"schema_version":"1.0","features":{"B01":false,"B02":false,"B03":false,"B04":false,"B05":false,"B06":false,"B07":false,"B08":false,"B09":false,"B10":true},"overall":"background"}

规则：
- 所有特征值必须是布尔值。
- 特征键必须保持 B01、B02、B03、B04、B05、B06、B07、B08、B09、B10 的顺序。
- 只有在没有观察到 B01 到 B09 时，才将 B10 设为 true；否则 B10 必须为 false。
- 当 B10 为 true 时，`overall` 必须是 `background`；否则必须是 `behavior_features_observed`。
- 不要输出解释、Markdown、置信度或 JSON 对象之外的任何文本。
