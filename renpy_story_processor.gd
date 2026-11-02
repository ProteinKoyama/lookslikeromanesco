class_name RenpyStoryProcessor
extends Node

## Ren'Py 由来の JSON を読み込み、ゲーム側が扱いやすいイベント辞書へ変換します。
## 表示・入力・Ren'Py の条件式評価は、このノードを利用するゲーム側が担当します。

signal event_ready(event: Dictionary)
signal story_finished

const STORY_JSON_PATH := "res://Assets/renpy_dialogues.json"
const STORY_FORMAT_VERSION := 3
const SAFE_NAME_PATTERN := "^[\\p{L}\\p{M}\\p{N} _　ー・-]{1,10}$"

var _flow: Array[Dictionary] = []
var _dialogues_by_id: Dictionary = {}
var _commands_by_id: Dictionary = {}
var _story_variables: Dictionary = {}
var _label_flow_indices: Dictionary = {}
var _menu_flow_indices: Dictionary = {}
var _flow_index_by_dialogue_id: Dictionary = {}
var _branch_boundaries: Array[Dictionary] = []
var _conditional_boundaries: Array[Dictionary] = []
var _flow_index := 0
var _pending_menu_flow_index := -1
var _waiting_for_response := false


# 公開 API: シナリオの読込と進行
func load_story(file_path: String = STORY_JSON_PATH) -> bool:
	# FileAccess と JSON は Godot の組み込み API です。読込・解析・構造確認を分けます。
	_clear_loaded_story()
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("シナリオ JSON を開けません: %s" % file_path)
		return false

	var json := JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	if parse_error != OK:
		push_error("シナリオ JSON の解析に失敗しました: %s" % json.get_error_message())
		return false

	var parsed_data: Variant = json.data
	if not parsed_data is Dictionary:
		push_error("シナリオ JSON のルートは Dictionary である必要があります。")
		return false

	var story_data: Dictionary = parsed_data
	if not _load_records(story_data):
		_clear_loaded_story()
		return false

	_build_indices()
	return true


func start_story() -> void:
	if _flow.is_empty():
		push_error("シナリオが読み込まれていないか、flow が空です。")
		return

	_reset_runtime_state()
	_flow_index = 0
	_dispatch_next_event()


func continue_story() -> void:
	if not _waiting_for_response or _pending_menu_flow_index >= 0:
		return

	_waiting_for_response = false
	_flow_index += 1
	_dispatch_next_event()


func select_choice(choice_index: int) -> void:
	if not _waiting_for_response or _pending_menu_flow_index < 0:
		return

	var menu_event: Dictionary = _flow[_pending_menu_flow_index]
	var menu_id := str(menu_event.get("id", ""))
	var choices := _get_menu_choices(menu_id)
	if choice_index < 0 or choice_index >= choices.size():
		push_error("選択肢の番号が範囲外です: %d" % choice_index)
		return

	var choice_value: Variant = choices[choice_index]
	if not choice_value is Dictionary:
		push_error("選択肢データが Dictionary ではありません: %s" % menu_id)
		return

	var choice: Dictionary = choice_value
	_apply_assignments(choice.get("assignments", []))
	var next_flow_index := _pending_menu_flow_index + 1
	var destination: Dictionary = choice.get("destination", {})
	_waiting_for_response = false
	_pending_menu_flow_index = -1
	_register_branch_boundary(destination)
	_flow_index = _get_choice_destination(choice, next_flow_index)
	_prune_conditional_boundaries_for_line(_get_flow_source_line(_flow_index))
	_prune_branch_boundaries_for_line(_get_flow_source_line(_flow_index))
	_dispatch_next_event()


func submit_text_input(value: String) -> bool:
	if not _waiting_for_response or _flow_index >= _flow.size():
		return false

	var input_event: Dictionary = _flow[_flow_index]
	if str(input_event.get("type", "")) != "text_input":
		return false

	var max_length := clampi(int(input_event.get("max_length", 10)), 1, 10)
	var accepted_value := value.strip_edges()
	if not _is_safe_story_name(accepted_value, max_length):
		return false

	var variable_name := str(input_event.get("variable", ""))
	if variable_name.is_empty():
		push_error("テキスト入力イベントに variable がありません。")
		return false

	_story_variables[variable_name] = accepted_value
	_waiting_for_response = false
	_flow_index += 1
	_dispatch_next_event()
	return true


func jump_to_label(label_name: String) -> void:
	if not _label_flow_indices.has(label_name):
		push_error("移動先のラベルが見つかりません: %s" % label_name)
		return

	_waiting_for_response = false
	_pending_menu_flow_index = -1
	var label_index := int(_label_flow_indices[label_name])
	_flow_index = label_index + 1
	_prune_conditional_boundaries_for_line(int(_flow[label_index].get("source_line", 0)))
	_prune_branch_boundaries_for_line(int(_flow[label_index].get("source_line", 0)))
	_dispatch_next_event()


func get_flow_size() -> int:
	return _flow.size()


func set_story_variable(variable_name: String, value: Variant) -> void:
	# 外部の入力UIも同じシナリオ変数へ値を渡せるようにします。
	_story_variables[variable_name] = value


# データ読込: JSON の形式を確認し、実行用インデックスを作成
func _load_records(story_data: Dictionary) -> bool:
	var format_version := int(story_data.get("format_version", 0))
	if format_version != STORY_FORMAT_VERSION:
		push_error(
			"シナリオ JSON の format_version が対応していません: %d (期待値: %d)"
			% [format_version, STORY_FORMAT_VERSION]
		)
		return false

	var flow_value: Variant = story_data.get("flow")
	if not flow_value is Array:
		push_error("シナリオ JSON に flow 配列がありません。")
		return false

	_flow.clear()
	for flow_entry_value: Variant in flow_value:
		if not flow_entry_value is Dictionary:
			push_error("flow の各要素は Dictionary である必要があります。")
			return false

		var flow_entry: Dictionary = flow_entry_value
		_flow.append(flow_entry)

	for index in range(1, _flow.size()):
		var previous_line := int(_flow[index - 1].get("source_line", 0))
		var current_line := int(_flow[index].get("source_line", 0))
		if current_line < previous_line:
			push_error("flow は source_line の昇順である必要があります。")
			return false

	if not _load_indexed_records(story_data, "dialogues", "id", _dialogues_by_id):
		return false
	if not _load_indexed_records(story_data, "commands", "id", _commands_by_id):
		return false
	if not _load_story_variables(story_data):
		return false

	return true


func _clear_loaded_story() -> void:
	_flow.clear()
	_dialogues_by_id.clear()
	_commands_by_id.clear()
	_story_variables.clear()
	_label_flow_indices.clear()
	_menu_flow_indices.clear()
	_flow_index_by_dialogue_id.clear()
	_reset_runtime_state()


func _reset_runtime_state() -> void:
	_flow_index = 0
	_pending_menu_flow_index = -1
	_waiting_for_response = false
	_branch_boundaries.clear()
	_conditional_boundaries.clear()


func _load_story_variables(story_data: Dictionary) -> bool:
	var variables_value: Variant = story_data.get("variables", {})
	if not variables_value is Dictionary:
		push_error("シナリオ JSON の variables は Dictionary である必要があります。")
		return false

	var story_variables: Dictionary = variables_value
	_story_variables = story_variables.duplicate(true)
	return true


func _load_indexed_records(
	story_data: Dictionary,
	array_key: String,
	index_key: String,
	index: Dictionary
) -> bool:
	var records_value: Variant = story_data.get(array_key)
	if not records_value is Array:
		push_error("シナリオ JSON に %s 配列がありません。" % array_key)
		return false

	index.clear()
	var records: Array = records_value
	for record_value: Variant in records:
		if not record_value is Dictionary:
			push_error("%s の各要素は Dictionary である必要があります。" % array_key)
			return false

		var record: Dictionary = record_value
		var record_id := str(record.get(index_key, ""))
		if record_id.is_empty():
			push_error("%s に %s がありません。" % [array_key, index_key])
			return false
		index[record_id] = record

	return true


func _build_indices() -> void:
	_label_flow_indices.clear()
	_menu_flow_indices.clear()
	_flow_index_by_dialogue_id.clear()

	for index in range(_flow.size()):
		var flow_entry: Dictionary = _flow[index]
		var event_type := str(flow_entry.get("type", ""))
		if event_type == "label":
			_label_flow_indices[str(flow_entry.get("name", ""))] = index
		elif event_type == "menu":
			_menu_flow_indices[str(flow_entry.get("id", ""))] = index
		elif event_type == "dialogue":
			_flow_index_by_dialogue_id[str(flow_entry.get("id", ""))] = index


# 進行制御: 次に表示するイベントを選択
func _dispatch_next_event() -> void:
	while _flow_index < _flow.size():
		if _skip_completed_branch():
			continue
		if _skip_completed_conditional_branch():
			continue

		var flow_entry: Dictionary = _flow[_flow_index]
		var event_type := str(flow_entry.get("type", ""))

		if event_type == "label":
			_flow_index += 1
			continue

		if event_type == "jump":
			var target_label := str(flow_entry.get("target_label", ""))
			if not _label_flow_indices.has(target_label):
				push_error("jump の移動先ラベルが見つかりません: %s" % target_label)
				return
			var target_index := int(_label_flow_indices[target_label])
			_prune_conditional_boundaries_for_line(int(_flow[target_index].get("source_line", 0)))
			_prune_branch_boundaries_for_line(int(_flow[target_index].get("source_line", 0)))
			_flow_index = target_index + 1
			continue

		if event_type == "if" or event_type == "elif" or event_type == "else":
			_process_condition(flow_entry)
			continue

		if event_type == "assignment":
			_apply_assignment(flow_entry)
			_flow_index += 1
			continue

		var event := _make_game_event(flow_entry)
		if event.is_empty():
			_flow_index += 1
			continue

		_waiting_for_response = true
		if event_type == "menu":
			_pending_menu_flow_index = _flow_index
		elif event.has("menu_id"):
			var menu_id := str(event.get("menu_id", ""))
			if _menu_flow_indices.has(menu_id):
				_pending_menu_flow_index = int(_menu_flow_indices[menu_id])
		event_ready.emit(event)
		return

	story_finished.emit()


func _make_game_event(flow_entry: Dictionary) -> Dictionary:
	var event_type := str(flow_entry.get("type", ""))
	var event := flow_entry.duplicate(true)

	match event_type:
		"dialogue":
			var dialogue_id := str(flow_entry.get("id", ""))
			if not _dialogues_by_id.has(dialogue_id):
				push_error("台詞 ID が見つかりません: %s" % dialogue_id)
				return {}

			var dialogue: Dictionary = _dialogues_by_id[dialogue_id]
			var character_name_before: Variant = _story_variables.get("character_name")
			var pre_assignments: Variant = dialogue.get("pre_assignments", [])
			if pre_assignments is Array:
				_apply_assignments(pre_assignments)
			if dialogue_id == "line_014":
				var character_name_after: Variant = _story_variables.get("character_name")
				var assignment_was_applied: bool = (
					character_name_before == null and character_name_after == "%s"
				)
				print(
					"[RenpyStoryProcessor] line_014 発話直前: 代入実行 = ",
					assignment_was_applied,
					", character_name = ",
					character_name_after
				)

			var speaker_id := str(dialogue.get("speaker", ""))
			var speaker_variable := str(dialogue.get("speaker_variable", ""))
			if speaker_id == "c":
				# Ren'Py の Character 名 c は識別子として扱い、表示名を character_name から解決します。
				var character_name_value: Variant = _story_variables.get("character_name")
				event["speaker"] = str(character_name_value) if character_name_value != null else ""
			elif not speaker_variable.is_empty():
				var speaker_value: Variant = _story_variables.get(speaker_variable)
				if speaker_value == null:
					event["speaker"] = str(dialogue.get("speaker", ""))
				else:
					event["speaker"] = str(speaker_value)
			else:
				event["speaker"] = dialogue.get("speaker")
			event["text"] = _interpolate_story_variables(str(dialogue.get("text", "")))
			event["label"] = str(dialogue.get("label", ""))
			var menu_id := str(dialogue.get("menu_id", ""))
			if not menu_id.is_empty():
				event["menu_id"] = menu_id
				event["choices"] = _get_menu_choices(menu_id)
		"menu":
			var menu_id := str(flow_entry.get("id", ""))
			event["choices"] = _get_menu_choices(menu_id)
		"visual_command":
			var command_id := str(flow_entry.get("id", ""))
			if not _commands_by_id.has(command_id):
				push_error("表示指示 ID が見つかりません: %s" % command_id)
				return {}

			event["command"] = _commands_by_id[command_id]
		_:
			# JSON にある条件と代入は dispatch 側で処理し、ゲーム画面へは表示イベントだけを送ります。
			pass

	return event


func _parse_dialog_choices(choice_values: Array) -> Array[Dictionary]:
	var dialog_choices: Array[Dictionary] = []
	for choice_value: Variant in choice_values:
		if not choice_value is Dictionary:
			push_error("JSON の選択肢は Dictionary である必要があります。")
			return []

		var choice: Dictionary = choice_value
		if not choice.get("text") is String:
			push_error("JSON の選択肢に String 型の text がありません。")
			return []

		# Dialog は text を表示し、同じ Dictionary 内の遷移情報を選択結果として返します。
		dialog_choices.append(choice.duplicate(true))

	return dialog_choices


func _get_menu_choices(menu_id: String) -> Array[Dictionary]:
	if not _menu_flow_indices.has(menu_id):
		push_error("メニュー ID が見つかりません: %s" % menu_id)
		return []

	var menu_flow_index := int(_menu_flow_indices[menu_id])
	var menu_event: Dictionary = _flow[menu_flow_index]
	var choices_value: Variant = menu_event.get("choices", [])
	if not choices_value is Array:
		push_error("flow の menu event に choices 配列がありません: %s" % menu_id)
		return []

	# 選択肢と遷移先は、時系列上の menu event にまとめて記述します。
	return _parse_dialog_choices(choices_value)


# 表示用データ: 台詞中の変数を置換し、入力値を検証
func _interpolate_story_variables(text: String) -> String:
	var result := text
	for variable_name: Variant in _story_variables:
		var variable_value: Variant = _story_variables[variable_name]
		if variable_value == null:
			continue
		result = result.replace(
			"[%s]" % str(variable_name),
			str(variable_value)
		)
	return result


func _is_safe_story_name(value: String, max_length: int) -> bool:
	if value.is_empty() or value.length() > max_length:
		return false

	# RegEx は Godot 組み込み API です。制御文字やタグ記号を許可しない名前の許可リストにします。
	var safe_name_regex := RegEx.new()
	safe_name_regex.compile(SAFE_NAME_PATTERN.replace("10", str(max_length)))
	return safe_name_regex.search(value) != null


func _process_condition(flow_entry: Dictionary) -> void:
	var condition_type := str(flow_entry.get("type", ""))
	var condition_passes := condition_type == "else"
	if condition_type != "else":
		condition_passes = bool(_evaluate_expression(str(flow_entry.get("expression", ""))))

	if condition_passes:
		var next_branch: Variant = flow_entry.get("next_branch_source_line")
		var continuation: Variant = flow_entry.get("continuation_source_line")
		if next_branch is int and continuation is int:
			_conditional_boundaries.append({
				"skip_at_source_line": next_branch,
				"continuation_source_line": continuation
			})
		_flow_index += 1
		return

	var next_branch_line: Variant = flow_entry.get("next_branch_source_line")
	var continuation_line: Variant = flow_entry.get("continuation_source_line")
	var target_line := int(next_branch_line) if next_branch_line is int else int(continuation_line)
	_flow_index = _find_flow_index_at_or_after_line(target_line)


func _skip_completed_conditional_branch() -> bool:
	if _conditional_boundaries.is_empty():
		return false

	var boundary: Dictionary = _conditional_boundaries.back()
	var current_line := int(_flow[_flow_index].get("source_line", 0))
	if current_line < int(boundary["skip_at_source_line"]):
		return false

	_conditional_boundaries.pop_back()
	_flow_index = _find_flow_index_at_or_after_line(int(boundary["continuation_source_line"]))
	return true


func _apply_assignments(assignments_value: Variant) -> void:
	if not assignments_value is Array:
		return

	for assignment_value: Variant in assignments_value:
		if assignment_value is Dictionary:
			_apply_assignment(assignment_value)


func _apply_assignment(assignment: Dictionary) -> void:
	var target := str(assignment.get("target", ""))
	if target.is_empty():
		push_error("変数代入イベントに target がありません。")
		return

	if bool(assignment.get("only_if_null", false)) and _story_variables.get(target) != null:
		return

	if assignment.has("generator"):
		if str(assignment.get("generator", "")) != "random_string":
			push_error("未対応の代入 generator です: %s" % assignment.get("generator"))
			return

		var minimum_length := clampi(int(assignment.get("min_length", 1)), 1, 10)
		var maximum_length := clampi(int(assignment.get("max_length", 10)), minimum_length, 10)
		var characters := str(assignment.get("characters", ""))
		if characters.is_empty():
			push_error("random_string の characters が空です。")
			return

		_story_variables[target] = _generate_random_string(
			minimum_length,
			maximum_length,
			characters
		)
		return

	if assignment.has("value"):
		_story_variables[target] = assignment["value"]
		return

	var expression := str(assignment.get("expression", ""))

	var random_choice := RegEx.new()
	random_choice.compile("^renpy\\.random\\.choice\\(([A-Za-z_]\\w*)\\)$")
	var choice_match := random_choice.search(expression)
	if choice_match != null:
		var choices_value: Variant = _story_variables.get(choice_match.get_string(1), [])
		if choices_value is Array and not choices_value.is_empty():
			_story_variables[target] = choices_value[randi_range(0, choices_value.size() - 1)]
			return

	_story_variables[target] = _evaluate_expression(expression)


func _generate_random_string(minimum_length: int, maximum_length: int, characters: String) -> String:
	# randi_range は Godot の乱数 API です。指定範囲の長さと文字を選んで名前を作ります。
	var generated_length := randi_range(minimum_length, maximum_length)
	var generated_name := ""
	for character_index in range(generated_length):
		var random_index := randi_range(0, characters.length() - 1)
		generated_name += characters.substr(random_index, 1)
	return generated_name


func _evaluate_expression(expression: String) -> Variant:
	# Ren'Py の randint 呼び出しを Godot の乱数値に置き換えてから式を評価します。
	var translated_expression := expression
	var random_integer := RegEx.new()
	random_integer.compile("renpy\\.random\\.randint\\(\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)")
	var random_match := random_integer.search(translated_expression)
	while random_match != null:
		var minimum := int(random_match.get_string(1))
		var maximum := int(random_match.get_string(2))
		translated_expression = translated_expression.replace(
			random_match.get_string(), str(randi_range(minimum, maximum))
		)
		random_match = random_integer.search(translated_expression)

	var input_names := PackedStringArray()
	var input_values: Array = []
	var variable_pattern := RegEx.new()
	variable_pattern.compile("[A-Za-z_]\\w*")
	for name_match: RegExMatch in variable_pattern.search_all(translated_expression):
		var variable_name := name_match.get_string()
		if variable_name in ["not", "and", "or", "true", "false", "null"]:
			continue
		if input_names.has(variable_name):
			continue
		input_names.append(variable_name)
		input_values.append(_story_variables.get(variable_name))

	# Expression は Godot 組み込みの式評価 API で、JSON の式と変数値を使って条件を判定します。
	var parsed_expression := Expression.new()
	var parse_error: Error = parsed_expression.parse(translated_expression, input_names)
	if parse_error != OK:
		push_error("条件式を解析できません: %s" % expression)
		return false

	var result: Variant = parsed_expression.execute(input_values, self, false)
	if parsed_expression.has_execute_failed():
		push_error("条件式を評価できません: %s" % expression)
		return false
	return result


# 分岐管理: 選択肢と条件ブロックの終端を処理
func _get_choice_destination(choice: Dictionary, default_index: int) -> int:
	var destination_value: Variant = choice.get("destination", {})
	if destination_value is Dictionary:
		var destination: Dictionary = destination_value
		var entry_line: Variant = destination.get("entry_source_line")
		if entry_line is int:
			return _find_flow_index_at_or_after_line(entry_line)

	var target_label := str(choice.get("target_label", ""))
	if not target_label.is_empty() and _label_flow_indices.has(target_label):
		return int(_label_flow_indices[target_label]) + 1

	var target_dialogue_id := str(choice.get("target_dialogue_id", ""))
	if not target_dialogue_id.is_empty() and _flow_index_by_dialogue_id.has(target_dialogue_id):
		return int(_flow_index_by_dialogue_id[target_dialogue_id])

	var target_source_line: Variant = choice.get("target_source_line")
	if target_source_line is int:
		return _find_flow_index_at_or_after_line(target_source_line)

	return default_index


func _find_flow_index_at_or_after_line(source_line: int) -> int:
	for index in range(_flow.size()):
		var flow_entry: Dictionary = _flow[index]
		if int(flow_entry.get("source_line", 0)) >= source_line:
			return index

	return _flow.size()


func _register_branch_boundary(destination: Dictionary) -> void:
	# JSON の暗黙 jump は、選択肢ブロック終了後に未選択の兄弟ブロックを飛ばします。
	var branch_end: Variant = destination.get("branch_end_source_line")
	var continuation: Variant = destination.get("continuation_source_line")
	var implicit_jump_value: Variant = destination.get("jump")
	if implicit_jump_value is Dictionary:
		var implicit_jump: Dictionary = implicit_jump_value
		continuation = implicit_jump.get("target_source_line", continuation)

	if branch_end is int and continuation is int:
		_branch_boundaries.append({
			"branch_end_source_line": branch_end,
			"continuation_source_line": continuation,
			"destination_type": str(destination.get("type", ""))
		})


func _skip_completed_branch() -> bool:
	if _branch_boundaries.is_empty():
		return false

	var boundary: Dictionary = _branch_boundaries.back()
	var branch_end := int(boundary["branch_end_source_line"])
	var current_line := int(_flow[_flow_index].get("source_line", 0))
	if current_line < branch_end:
		return false

	_branch_boundaries.pop_back()
	if boundary.get("destination_type") == "return":
		_flow_index = _flow.size()
		return true

	var continuation_line := int(boundary["continuation_source_line"])
	_flow_index = _find_flow_index_at_or_after_line(continuation_line)
	return true


func _prune_branch_boundaries_for_line(target_line: int) -> void:
	while not _branch_boundaries.is_empty():
		var boundary: Dictionary = _branch_boundaries.back()
		var branch_end := int(boundary["branch_end_source_line"])
		if target_line < branch_end:
			return
		_branch_boundaries.pop_back()


func _prune_conditional_boundaries_for_line(target_line: int) -> void:
	while not _conditional_boundaries.is_empty():
		var boundary: Dictionary = _conditional_boundaries.back()
		if target_line < int(boundary["skip_at_source_line"]):
			return
		_conditional_boundaries.pop_back()


func _get_flow_source_line(flow_index: int) -> int:
	if flow_index < 0 or flow_index >= _flow.size():
		return 2147483647

	return int(_flow[flow_index].get("source_line", 0))
