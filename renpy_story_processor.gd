class_name RenpyStoryProcessor
extends Node

## script.rpy を読み込み、対応する Ren'Py 文を順に実行して Dialog へ渡します。

signal event_ready(event: Dictionary)
signal story_finished

const STORY_FILE_PATH := "res://Assets/script.rpy"
const SAFE_NAME_PATTERN := "^[\\p{L}\\p{M}\\p{N} _　ー・-]{0,10}$"

var _tokens: Array[Dictionary] = []
var _parse_index := 0
var _parse_error := ""
var last_load_error := ""
var _program: Array[Dictionary] = []
var _program_counter := 0
var _label_program_indices: Dictionary = {}
var _default_variables: Dictionary = {}
var _defined_variables: Dictionary = {}
var _story_variables: Dictionary = {}
var _pending_choice_targets: Array[int] = []
var _pending_input_variable := ""
var _waiting_for_response := false
var _call_stack: Array[int] = []
var _random := RandomNumberGenerator.new()
var _current_event: Dictionary = {}


func load_story(file_path: String = STORY_FILE_PATH) -> bool:
	last_load_error = ""
	# FileAccess は Godot の組み込み API で、プロジェクト内の script.rpy を読み込みます。
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		last_load_error = "Ren'Py シナリオを開けません: %s" % file_path
		push_error(last_load_error)
		return false

	_tokens.clear()
	_parse_index = 0
	_parse_error = ""
	if not _tokenize_source(file.get_as_text().trim_prefix("\uFEFF")):
		last_load_error = _parse_error
		return false

	var root_nodes := _parse_block(0)
	if not _parse_error.is_empty():
		last_load_error = _parse_error
		push_error(last_load_error)
		return false
	if _parse_index < _tokens.size():
		var unexpected: Dictionary = _tokens[_parse_index]
		last_load_error = "未対応のインデントです (%d行): %s" % [unexpected.line, unexpected.text]
		push_error(last_load_error)
		return false

	_default_variables.clear()
	_defined_variables.clear()
	_program.clear()
	_label_program_indices.clear()
	_collect_declarations(root_nodes)
	_compile_nodes(root_nodes)
	if not _parse_error.is_empty():
		last_load_error = _parse_error
		push_error(last_load_error)
		return false
	if not _label_program_indices.has("start"):
		last_load_error = "script.rpy に label start がありません。"
		push_error(last_load_error)
		return false
	return true


func start_story() -> void:
	if _program.is_empty():
		push_error("Ren'Py シナリオが読み込まれていません。")
		return

	_story_variables = _default_variables.duplicate(true)
	_story_variables.merge(_defined_variables, true)
	_pending_choice_targets.clear()
	_pending_input_variable = ""
	_call_stack.clear()
	_waiting_for_response = false
	_current_event.clear()
	# RandomNumberGenerator は Godot API です。Ren'Py の random.choice/randint に使います。
	_random.randomize()
	_program_counter = int(_label_program_indices["start"])
	_run_until_event()


func continue_story() -> void:
	if not _waiting_for_response:
		return

	_waiting_for_response = false
	_current_event.clear()
	_run_until_event()


func select_choice(choice_index: int) -> void:
	if not _waiting_for_response:
		return
	if choice_index < 0 or choice_index >= _pending_choice_targets.size():
		push_error("選択肢の番号が範囲外です: %d" % choice_index)
		return

	_program_counter = _pending_choice_targets[choice_index]
	_pending_choice_targets.clear()
	_waiting_for_response = false
	_current_event.clear()
	_run_until_event()


func submit_text_input(value: String) -> bool:
	if not _waiting_for_response or _pending_input_variable.is_empty():
		return false

	var accepted_value := value.strip_edges()
	if not _is_safe_input(accepted_value):
		return false

	_story_variables[_pending_input_variable] = accepted_value
	_pending_input_variable = ""
	_waiting_for_response = false
	_current_event.clear()
	_run_until_event()
	return true


func create_save_data() -> Dictionary:
	if not _waiting_for_response:
		return {}
	var event_type := str(_current_event.get("type", ""))
	if event_type not in ["dialogue", "menu", "text_input"]:
		return {}

	return {
		"format_version": 1,
		"program_counter": _program_counter,
		"story_variables": _story_variables.duplicate(true),
		"call_stack": _call_stack.duplicate(),
		"pending_choice_targets": _pending_choice_targets.duplicate(),
		"pending_input_variable": _pending_input_variable,
		"random_state": _random.state,
		"current_event": _current_event.duplicate(true)
	}


func restore_save_data(save_data: Dictionary) -> bool:
	if int(save_data.get("format_version", 0)) != 1:
		push_warning("このセーブデータ形式には対応していません。")
		return false

	var saved_program_counter := int(save_data.get("program_counter", -1))
	var variables_value: Variant = save_data.get("story_variables")
	var call_stack_value: Variant = save_data.get("call_stack")
	var choice_targets_value: Variant = save_data.get("pending_choice_targets")
	var event_value: Variant = save_data.get("current_event")
	if saved_program_counter < 0 or saved_program_counter > _program.size():
		push_warning("セーブデータのシナリオ位置が正しくありません。")
		return false
	if not variables_value is Dictionary or not call_stack_value is Array:
		push_warning("セーブデータのシナリオ状態が正しくありません。")
		return false
	if not choice_targets_value is Array or not event_value is Dictionary:
		push_warning("セーブデータの入力状態が正しくありません。")
		return false
	var event_type := str(event_value.get("type", ""))
	if event_type not in ["dialogue", "menu", "text_input"]:
		push_warning("セーブデータに再開可能な表示内容がありません。")
		return false

	_program_counter = saved_program_counter
	_story_variables = variables_value.duplicate(true)
	_call_stack.clear()
	for stack_value: Variant in call_stack_value:
		_call_stack.append(int(stack_value))
	_pending_choice_targets.clear()
	for target_value: Variant in choice_targets_value:
		_pending_choice_targets.append(int(target_value))
	_pending_input_variable = str(save_data.get("pending_input_variable", ""))
	_random.state = int(save_data.get("random_state", _random.state))
	_waiting_for_response = true
	_current_event = event_value.duplicate(true)
	# ロード時は保存した表示イベントを再送し、Dialog に現在行と入力 UI を復元します。
	event_ready.emit(_current_event.duplicate(true))
	return true


# 字句解析: インデントと行番号を残し、コメントと空行を除きます。
func _tokenize_source(source: String) -> bool:
	var source_lines := source.split("\n")
	for line_index in range(source_lines.size()):
		var raw_line: String = source_lines[line_index].trim_suffix("\r")
		if raw_line.strip_edges().is_empty() or raw_line.strip_edges().begins_with("#"):
			continue

		var indentation := 0
		for character in raw_line:
			if character == " ":
				indentation += 1
			elif character == "\t":
				indentation += 4
			else:
				break

		_tokens.append({
			"line": line_index + 1,
			"indent": indentation,
			"text": raw_line.strip_edges()
		})
	return true


func _parse_block(expected_indent: int) -> Array[Dictionary]:
	var statements: Array[Dictionary] = []
	while _parse_index < _tokens.size():
		var token: Dictionary = _tokens[_parse_index]
		var indentation := int(token.indent)
		if indentation < expected_indent:
			break
		if indentation > expected_indent:
			_parse_error = "予期しないインデント (%d行): %s" % [token.line, token.text]
			break
		if _is_if_branch_header(str(token.text)):
			break

		var statement := _parse_statement(expected_indent)
		if not _parse_error.is_empty():
			break
		if not statement.is_empty():
			statements.append(statement)

	return statements


func _parse_statement(indentation: int) -> Dictionary:
	var token: Dictionary = _tokens[_parse_index]
	var source_line := int(token.line)
	var text := str(token.text)

	if text.begins_with("label ") and text.ends_with(":"):
		var label_name := text.trim_prefix("label ").trim_suffix(":").strip_edges()
		_parse_index += 1
		return {
			"type": "label",
			"name": label_name,
			"line": source_line,
			"body": _parse_block(indentation + 4)
		}

	if text.begins_with("menu") and text.ends_with(":"):
		return _parse_menu(indentation, source_line)

	if _is_if_header(text):
		return _parse_if(indentation)

	if text == "python:":
		return _parse_python_block(indentation, source_line)

	if text.begins_with("default "):
		_parse_index += 1
		var default_assignment := _parse_assignment(text.trim_prefix("default "), source_line)
		default_assignment["type"] = "default"
		return default_assignment

	if text.begins_with("define "):
		_parse_index += 1
		var definition := _parse_assignment(text.trim_prefix("define "), source_line)
		definition["type"] = "define"
		return definition

	if text.begins_with("jump "):
		_parse_index += 1
		return {"type": "jump", "target": text.trim_prefix("jump ").strip_edges(), "line": source_line}

	if text.begins_with("call "):
		_parse_index += 1
		return {"type": "call", "target": text.trim_prefix("call ").strip_edges(), "line": source_line}

	if text == "return":
		_parse_index += 1
		return {"type": "return", "line": source_line}

	if text == "pass":
		_parse_index += 1
		return {"type": "noop", "line": source_line}

	if text.begins_with("$"):
		_parse_index += 1
		return _parse_assignment(text.trim_prefix("$").strip_edges(), source_line)

	if text.begins_with("scene ") or text.begins_with("show ") or text.begins_with("hide ") or text.begins_with("with "):
		_parse_index += 1
		var command := text
		var transform_nodes: Array[Dictionary] = []
		if command.ends_with(":"):
			command = command.trim_suffix(":")
			transform_nodes = _parse_block(indentation + 4)
		return {
			"type": "visual",
			"command": command,
			"transform": transform_nodes,
			"line": source_line
		}

	if text.begins_with("zoom "):
		_parse_index += 1
		return {
			"type": "transform",
			"zoom": text.trim_prefix("zoom ").to_float(),
			"line": source_line
		}

	var dialogue := _parse_dialogue(text, source_line)
	if not dialogue.is_empty():
		_parse_index += 1
		return dialogue

	var assignment := _parse_assignment(text, source_line)
	if not assignment.is_empty():
		_parse_index += 1
		return assignment

	_parse_error = "未対応の Ren'Py 文です (%d行): %s" % [source_line, text]
	_parse_index += 1
	return {}


func _parse_python_block(indentation: int, source_line: int) -> Dictionary:
	_parse_index += 1
	var body: Array[Dictionary] = []
	var block_indent := indentation + 4
	while _parse_index < _tokens.size():
		var token: Dictionary = _tokens[_parse_index]
		if int(token.indent) < block_indent:
			break
		if int(token.indent) > block_indent:
			_parse_error = "未対応の Python インデント (%d行): %s" % [token.line, token.text]
			break

		var python_line := str(token.text)
		if _is_if_header(python_line):
			body.append(_parse_if(block_indent))
			continue
		var assignment := _parse_assignment(python_line, int(token.line))
		if assignment.is_empty():
			_parse_error = "未対応の Python 文です (%d行): %s" % [token.line, python_line]
			_parse_index += 1
			break
		body.append(assignment)
		_parse_index += 1
	return {"type": "python_block", "body": body, "line": source_line}


func _parse_if(indentation: int) -> Dictionary:
	var branches: Array[Dictionary] = []
	var source_line := int(_tokens[_parse_index].line)
	while _parse_index < _tokens.size():
		var token: Dictionary = _tokens[_parse_index]
		var text := str(token.text)
		var is_first_branch := branches.is_empty()
		var is_valid_header := _is_if_header(text) if is_first_branch else _is_if_branch_header(text)
		if int(token.indent) != indentation or not is_valid_header:
			break

		var expression := ""
		var is_else := text.begins_with("else")
		if _is_if_header(text):
			expression = _header_expression(text, "if")
		elif text.begins_with("elif "):
			expression = _header_expression(text, "elif")
		_parse_index += 1
		branches.append({
			"expression": expression,
			"otherwise": is_else,
			"body": _parse_block(indentation + 4)
		})
		if _parse_index >= _tokens.size():
			break
		var next_token: Dictionary = _tokens[_parse_index]
		if int(next_token.indent) != indentation or not _is_if_branch_header(str(next_token.text)):
			break

	return {"type": "if", "branches": branches, "line": source_line}


func _parse_menu(indentation: int, source_line: int) -> Dictionary:
	_parse_index += 1
	var menu_prompt := ""
	var choices: Array[Dictionary] = []
	var block_indent := indentation + 4

	while _parse_index < _tokens.size():
		var token: Dictionary = _tokens[_parse_index]
		if int(token.indent) < block_indent:
			break
		if int(token.indent) > block_indent:
			_parse_error = "予期しない menu インデント (%d行): %s" % [token.line, token.text]
			break

		var choice_header := _parse_menu_choice_header(str(token.text))
		if not choice_header.is_empty():
			_parse_index += 1
			choices.append({
				"text": choice_header.text,
				"condition": choice_header.condition,
				"body": _parse_block(block_indent + 4),
				"line": token.line
			})
			continue

		var prompt := _parse_dialogue(str(token.text), int(token.line))
		if prompt.is_empty() and str(token.text).begins_with("\""):
			var quoted := _read_quoted_value(str(token.text), 0)
			if not quoted.is_empty() and str(token.text).substr(int(quoted.end)).strip_edges().is_empty():
				prompt = {"type": "dialogue", "speaker": "", "text": quoted.value, "line": token.line}
		if not prompt.is_empty():
			menu_prompt = str(prompt.text)
			_parse_index += 1
			continue

		_parse_error = "未対応の menu 文です (%d行): %s" % [token.line, token.text]
		_parse_index += 1
		break

	if choices.is_empty() and _parse_error.is_empty():
		_parse_error = "menu に選択肢がありません (%d行)。" % source_line
	return {
		"type": "menu",
		"prompt": menu_prompt,
		"choices": choices,
		"line": source_line
	}


func _parse_dialogue(text: String, source_line: int) -> Dictionary:
	if text.begins_with("\""):
		var narration := _read_quoted_value(text, 0)
		if not narration.is_empty() and text.substr(int(narration.end)).strip_edges().is_empty():
			return {"type": "dialogue", "speaker": "", "text": narration.value, "line": source_line}
		return {}

	var speaker_end := text.find(" ")
	if speaker_end <= 0:
		return {}
	var speaker_and_attributes := text.substr(0, speaker_end)
	var speaker := speaker_and_attributes
	var image_attributes := ""
	var attribute_separator := speaker_and_attributes.find("@")
	if attribute_separator >= 0:
		speaker = speaker_and_attributes.substr(0, attribute_separator)
		image_attributes = speaker_and_attributes.substr(attribute_separator + 1)
	if not _is_identifier(speaker):
		return {}
	var quote_start := text.find("\"", speaker_end)
	if quote_start < 0:
		return {}
	var spoken_text := _read_quoted_value(text, quote_start)
	if spoken_text.is_empty() or not text.substr(int(spoken_text.end)).strip_edges().is_empty():
		return {}
	return {
		"type": "dialogue",
		"speaker": speaker,
		"image_attributes": image_attributes,
		"text": spoken_text.value,
		"line": source_line
	}


func _parse_menu_choice_header(text: String) -> Dictionary:
	if not text.begins_with("\""):
		return {}
	var quoted := _read_quoted_value(text, 0)
	if quoted.is_empty():
		return {}
	var suffix := text.substr(int(quoted.end)).strip_edges()
	if not suffix.ends_with(":"):
		return {}
	suffix = suffix.trim_suffix(":").strip_edges()
	var condition := ""
	if not suffix.is_empty():
		if not suffix.begins_with("if "):
			return {}
		condition = suffix.trim_prefix("if ").strip_edges()
	return {"text": quoted.value, "condition": condition}


func _parse_assignment(text: String, source_line: int) -> Dictionary:
	var assignment_regex := RegEx.new()
	assignment_regex.compile("^([A-Za-z_]\\w*)\\s*(\\+=|-=|\\*=|/=|=)\\s*(.+)$")
	var assignment_match := assignment_regex.search(text)
	if assignment_match == null:
		return {}

	var target := assignment_match.get_string(1)
	var operator := assignment_match.get_string(2)
	var expression := assignment_match.get_string(3).strip_edges()
	var input_call := _parse_input_call(expression)
	if not input_call.is_empty():
		input_call["type"] = "text_input"
		input_call["target"] = target
		input_call["line"] = source_line
		return input_call

	return {
		"type": "assignment",
		"target": target,
		"operator": operator,
		"expression": expression,
		"line": source_line
	}


func _parse_input_call(expression: String) -> Dictionary:
	if not expression.begins_with("renpy.input(") or not expression.ends_with(")"):
		return {}
	var argument_text := expression.substr("renpy.input(".length())
	argument_text = argument_text.trim_suffix(")").strip_edges()
	var quoted := _read_quoted_value(argument_text, 0)
	if quoted.is_empty():
		return {}
	var remainder := argument_text.substr(int(quoted.end)).strip_edges()
	var maximum_length := 10
	var length_regex := RegEx.new()
	length_regex.compile("(?:^|,)\\s*length\\s*=\\s*(\\d+)")
	var length_match := length_regex.search(remainder)
	if length_match != null:
		maximum_length = clampi(int(length_match.get_string(1)), 1, 10)
	return {"prompt": quoted.value, "max_length": maximum_length}


func _read_quoted_value(text: String, start_index: int) -> Dictionary:
	if start_index < 0 or start_index >= text.length() or text.substr(start_index, 1) != "\"":
		return {}

	var escaped := false
	for character_index in range(start_index + 1, text.length()):
		var character := text.substr(character_index, 1)
		if escaped:
			escaped = false
			continue
		if character == "\\":
			escaped = true
			continue
		if character == "\"":
			var literal := text.substr(start_index, character_index - start_index + 1)
			# JSON.parse_string は引用符内の Ren'Py エスケープ文字列を GDS の String に変換します。
			var parsed_value: Variant = JSON.parse_string(literal)
			if parsed_value is String:
				return {"value": parsed_value, "end": character_index + 1}
			return {}
	return {}


func _is_if_branch_header(text: String) -> bool:
	return text.begins_with("elif ") or text.begins_with("elif(") or text == "else:" or text == "else :"


func _is_if_header(text: String) -> bool:
	return text.begins_with("if ") or text.begins_with("if(")


func _header_expression(text: String, keyword: String) -> String:
	return text.trim_prefix(keyword).trim_suffix(":").strip_edges()


func _is_identifier(value: String) -> bool:
	var identifier_regex := RegEx.new()
	identifier_regex.compile("^[A-Za-z_]\\w*$")
	return identifier_regex.search(value) != null


# コンパイル: インデントブロックを、ジャンプ可能な実行命令列へ変換します。
func _collect_declarations(root_nodes: Array[Dictionary]) -> void:
	for statement in root_nodes:
		var statement_type := str(statement.get("type", ""))
		if statement_type == "default":
			_default_variables[str(statement.target)] = _evaluate_value(str(statement.expression))
		elif statement_type == "define":
			var variable_name := str(statement.target)
			if variable_name != "c":
				_defined_variables[variable_name] = _evaluate_value(str(statement.expression))


func _compile_nodes(statements: Array[Dictionary]) -> void:
	for statement in statements:
		var statement_type := str(statement.get("type", ""))
		match statement_type:
			"default", "define", "noop":
				continue
			"label":
				_program.append({"op": "label", "name": str(statement.name), "line": int(statement.line)})
				if _label_program_indices.has(str(statement.name)):
					_parse_error = "label が重複しています: %s" % statement.name
					return
				_label_program_indices[str(statement.name)] = _program.size()
				_compile_nodes(statement.body)
			"block", "python_block":
				_compile_nodes(statement.body)
			"if":
				_compile_if(statement)
			"menu":
				_compile_menu(statement)
			"dialogue":
				_program.append({
					"op": "dialogue",
					"speaker": str(statement.speaker),
					"text": str(statement.text),
					"line": int(statement.line)
				})
			"assignment":
				_program.append({"op": "assignment", "statement": statement})
			"text_input":
				_program.append({"op": "text_input", "statement": statement})
			"jump", "call":
				_program.append({
					"op": statement_type,
					"target": str(statement.target),
					"line": int(statement.line)
				})
			"return":
				_program.append({"op": "return", "line": int(statement.line)})
			"visual":
				var zoom := 0.0
				for transform_value: Variant in statement.get("transform", []):
					if transform_value is Dictionary and transform_value.get("type") == "transform":
						zoom = float(transform_value.get("zoom", 0.0))
				_program.append({
					"op": "visual",
					"command": str(statement.command),
					"zoom": zoom,
					"line": int(statement.line)
				})
			"transform":
				continue
			_:
				_parse_error = "未対応の構文ノードです: %s" % statement_type
				return


func _compile_if(statement: Dictionary) -> void:
	var branches: Array = statement.get("branches", [])
	var pending_condition_index := -1
	var end_jump_indices: Array[int] = []

	for branch_index in range(branches.size()):
		var branch: Dictionary = branches[branch_index]
		var branch_start := _program.size()
		if pending_condition_index >= 0:
			_program[pending_condition_index].false_target = branch_start
			pending_condition_index = -1

		if not bool(branch.otherwise):
			pending_condition_index = _program.size()
			_program.append({
				"op": "condition",
				"expression": str(branch.expression),
				"false_target": -1,
				"line": int(statement.line)
			})
		_compile_nodes(branch.body)
		if branch_index < branches.size() - 1:
			end_jump_indices.append(_program.size())
			_program.append({"op": "jump_pc", "target_pc": -1})

	var end_index := _program.size()
	if pending_condition_index >= 0:
		_program[pending_condition_index].false_target = end_index
	for jump_index in end_jump_indices:
		_program[jump_index].target_pc = end_index


func _compile_menu(statement: Dictionary) -> void:
	var branches: Array = statement.get("choices", [])
	var menu_instruction_index := _program.size()
	_program.append({
		"op": "menu",
		"prompt": str(statement.get("prompt", "")),
		"choices": [],
		"end_pc": -1,
		"line": int(statement.line)
	})

	var compiled_choices: Array[Dictionary] = []
	var end_jump_indices: Array[int] = []
	for branch in branches:
		var choice_target := _program.size()
		_compile_nodes(branch.body)
		end_jump_indices.append(_program.size())
		_program.append({"op": "jump_pc", "target_pc": -1})
		compiled_choices.append({
			"text": str(branch.text),
			"condition": str(branch.condition),
			"target_pc": choice_target
		})

	var end_index := _program.size()
	for jump_index in end_jump_indices:
		_program[jump_index].target_pc = end_index
	_program[menu_instruction_index].choices = compiled_choices
	_program[menu_instruction_index].end_pc = end_index


# 実行: 内部命令を処理し、表示や入力が必要なときだけ Dialog へイベントを渡します。
func _run_until_event() -> void:
	while _program_counter < _program.size():
		var instruction: Dictionary = _program[_program_counter]
		_program_counter += 1
		var operation := str(instruction.get("op", ""))
		match operation:
			"label":
				continue
			"jump_pc":
				_program_counter = int(instruction.target_pc)
				continue
			"condition":
				if not bool(_evaluate_expression(str(instruction.expression))):
					_program_counter = int(instruction.false_target)
				continue
			"assignment":
				_apply_assignment(instruction.statement)
				continue
			"jump":
				if not _jump_to_label(str(instruction.target)):
					return
				continue
			"call":
				if not _label_program_indices.has(str(instruction.target)):
					push_error("call 先の label がありません: %s" % instruction.target)
					return
				_call_stack.append(_program_counter)
				_program_counter = int(_label_program_indices[instruction.target])
				continue
			"return":
				if _call_stack.is_empty():
					story_finished.emit()
					return
				_program_counter = int(_call_stack.pop_back())
				continue
			"dialogue":
				_publish_waiting_event({
					"type": "dialogue",
					"speaker": _resolve_speaker(str(instruction.speaker)),
					"text": _interpolate_text(str(instruction.text)),
					"source_line": int(instruction.line)
				})
				return
			"menu":
				if not _present_menu(instruction):
					continue
				return
			"text_input":
				var input_statement: Dictionary = instruction.statement
				_pending_input_variable = str(input_statement.target)
				_publish_waiting_event({
					"type": "text_input",
					"prompt": _interpolate_text(str(input_statement.prompt)),
					"max_length": int(input_statement.max_length),
					"source_line": int(input_statement.line)
				})
				return
			"visual":
				_publish_waiting_event({
					"type": "visual_command",
					"command": str(instruction.command),
					"zoom": float(instruction.zoom),
					"source_line": int(instruction.line)
				})
				return
			_:
				push_error("未対応の実行命令です: %s" % operation)
				return

	story_finished.emit()


func _present_menu(instruction: Dictionary) -> bool:
	var visible_choices: Array[Dictionary] = []
	_pending_choice_targets.clear()
	for choice_value: Variant in instruction.choices:
		if not choice_value is Dictionary:
			continue
		var choice: Dictionary = choice_value
		var condition := str(choice.get("condition", ""))
		if not condition.is_empty() and not bool(_evaluate_expression(condition)):
			continue
		visible_choices.append({"text": str(choice.text)})
		_pending_choice_targets.append(int(choice.target_pc))

	if visible_choices.is_empty():
		_program_counter = int(instruction.end_pc)
		return false

	var prompt := _interpolate_text(str(instruction.prompt))
	if prompt.is_empty():
		_publish_waiting_event({"type": "menu", "choices": visible_choices, "source_line": int(instruction.line)})
	else:
		_publish_waiting_event({
			"type": "menu",
			"prompt": prompt,
			"choices": visible_choices,
			"source_line": int(instruction.line)
		})
	return true


func _publish_waiting_event(event: Dictionary) -> void:
	_waiting_for_response = true
	_current_event = event.duplicate(true)
	event_ready.emit(_current_event.duplicate(true))


func _jump_to_label(label_name: String) -> bool:
	if not _label_program_indices.has(label_name):
		push_error("jump 先の label がありません: %s" % label_name)
		return false
	_program_counter = int(_label_program_indices[label_name])
	return true


func _resolve_speaker(speaker_id: String) -> String:
	if speaker_id != "c":
		return speaker_id
	var character_name: Variant = _story_variables.get("character_name", "")
	return str(character_name) if character_name != null else ""


func _interpolate_text(source_text: String) -> String:
	var result := source_text
	for variable_name: Variant in _story_variables:
		var variable_value: Variant = _story_variables[variable_name]
		if variable_value == null:
			continue
		result = result.replace("[%s]" % str(variable_name), str(variable_value))
	return result


func _apply_assignment(statement: Dictionary) -> void:
	var target := str(statement.target)
	var operator := str(statement.operator)
	var expression := str(statement.expression)
	var value: Variant
	var random_slice := RegEx.new()
	random_slice.compile("^([A-Za-z_]\\w*)\\[:renpy\\.random\\.randint\\((\\d+),(\\d+)\\)\\]$")
	var slice_match := random_slice.search(expression)
	if slice_match != null:
		var source_value := str(_story_variables.get(slice_match.get_string(1), ""))
		var minimum_length := int(slice_match.get_string(2))
		var maximum_length := int(slice_match.get_string(3))
		var slice_length := _random.randi_range(minimum_length, maximum_length)
		value = source_value.substr(0, slice_length)
	elif expression.ends_with(".strip()"):
		var source_variable := expression.trim_suffix(".strip()")
		value = str(_story_variables.get(source_variable, "")).strip_edges()
	else:
		value = _evaluate_value(expression)

	if operator != "=":
		var left_value: Variant = _story_variables.get(target, 0)
		var full_expression := _assignment_expression(operator, left_value, value)
		value = _evaluate_expression(full_expression)
	_story_variables[target] = value


func _assignment_expression(operator: String, left_value: Variant, right_value: Variant) -> String:
	var operation := operator.trim_suffix("=")
	return "%s %s %s" % [str(left_value), operation, str(right_value)]


func _evaluate_value(expression: String) -> Variant:
	var value := expression.strip_edges()
	if value == "True":
		return true
	if value == "False":
		return false
	if value == "None":
		return null

	var random_choice := RegEx.new()
	random_choice.compile("^renpy\\.random\\.choice\\(([A-Za-z_]\\w*)\\)$")
	var choice_match := random_choice.search(value)
	if choice_match != null:
		var choices_value: Variant = _story_variables.get(choice_match.get_string(1), _defined_variables.get(choice_match.get_string(1), []))
		if choices_value is Array and not choices_value.is_empty():
			return choices_value[_random.randi_range(0, choices_value.size() - 1)]

	var parsed_value: Variant = JSON.parse_string(value)
	if parsed_value != null or value == "null":
		return parsed_value
	if value.is_valid_int():
		return int(value)
	if value.is_valid_float():
		return float(value)
	return _evaluate_expression(value)


func _evaluate_expression(expression: String) -> Variant:
	var translated := expression.replace("True", "true").replace("False", "false")
	var random_integer := RegEx.new()
	random_integer.compile("renpy\\.random\\.randint\\(\\s*(-?\\d+)\\s*,\\s*(-?\\d+)\\s*\\)")
	var random_match := random_integer.search(translated)
	while random_match != null:
		var minimum := int(random_match.get_string(1))
		var maximum := int(random_match.get_string(2))
		translated = translated.replace(
			random_match.get_string(), str(_random.randi_range(minimum, maximum))
		)
		random_match = random_integer.search(translated)

	var input_names := PackedStringArray()
	var input_values: Array = []
	var variable_regex := RegEx.new()
	variable_regex.compile("[A-Za-z_]\\w*")
	for variable_match: RegExMatch in variable_regex.search_all(translated):
		var variable_name := variable_match.get_string()
		if variable_name in ["not", "and", "or", "true", "false", "null"]:
			continue
		if input_names.has(variable_name):
			continue
		input_names.append(variable_name)
		input_values.append(_story_variables.get(variable_name, _defined_variables.get(variable_name)))

	# Expression は Godot の式評価 API です。Ren'Py の条件・算術式を安全に評価します。
	var parsed_expression := Expression.new()
	var parse_error: Error = parsed_expression.parse(translated, input_names)
	if parse_error != OK:
		push_error("Ren'Py 式を解析できません: %s" % expression)
		return false
	var result: Variant = parsed_expression.execute(input_values, self, false)
	if parsed_expression.has_execute_failed():
		push_error("Ren'Py 式を評価できません: %s" % expression)
		return false
	return result


func _is_safe_input(value: String) -> bool:
	if value.length() > 10:
		return false
	var safe_regex := RegEx.new()
	safe_regex.compile(SAFE_NAME_PATTERN)
	return safe_regex.search(value) != null
