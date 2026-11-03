extends Control

## Ren'Py スクリプトから受け取った台詞と選択肢を表示する会話コンポーネントです。

signal choice_selected(choice_index: int, choice: Dictionary)
signal advance_requested
signal options_toggle_requested
signal text_input_submitted(value: String)

const SKIP_CHARACTERS_PER_SECOND := 300.0
const SKIP_LINE_DELAY_SECONDS := 0.05
const DEFAULT_NAME_INPUT_LENGTH := 10
const SAFE_NAME_PATTERN := "^[\\p{L}\\p{M}\\p{N} _　ー・-]{0,10}$"

@onready var speaker_label: Label = $DialoguePanel/Margin/Layout/SpeakerName
@onready var dialogue_label: Label = $DialoguePanel/Margin/Layout/DialogueText
@onready var choice_scroll_container: ScrollContainer = $ChoiceScrollContainer
@onready var choice_list: VBoxContainer = $ChoiceScrollContainer/ChoiceCenterContainer/ChoiceVBoxContainer
@onready var auto_button: Button = $DialoguePanel/Margin/Layout/HBoxContainer/AutoButton
@onready var skip_button: Button = $DialoguePanel/Margin/Layout/HBoxContainer/SkipButton
@onready var setting_button: Button = $DialoguePanel/Margin/Layout/HBoxContainer/SettingButton
@onready var text_input_container: VBoxContainer = $ChoiceScrollContainer/ChoiceCenterContainer/TextInputVBoxContainer
@onready var text_input_prompt: Label = $ChoiceScrollContainer/ChoiceCenterContainer/TextInputVBoxContainer/PromptLabel
@onready var name_line_edit: LineEdit = $ChoiceScrollContainer/ChoiceCenterContainer/TextInputVBoxContainer/NameLineEdit
@onready var text_input_submit_button: Button = $ChoiceScrollContainer/ChoiceCenterContainer/TextInputVBoxContainer/SubmitButton
@onready var text_input_validation_label: Label = $ChoiceScrollContainer/ChoiceCenterContainer/TextInputVBoxContainer/ValidationLabel
@onready var typing_sound: AudioStreamPlayer = $TypingSound
@onready var backlog_panel: PanelContainer = $BacklogPanel
@onready var backlog_input_blocker: Control = $BacklogInputBlocker
@onready var backlog_close_button: Button = $BacklogPanel/BacklogMargin/BacklogLayout/BacklogHeader/BacklogCloseButton
@onready var backlog_scroll: ScrollContainer = $BacklogPanel/BacklogMargin/BacklogLayout/BacklogScroll
@onready var backlog_text: RichTextLabel = $BacklogPanel/BacklogMargin/BacklogLayout/BacklogScroll/BacklogText

var options_menu: Control
var backlog_entries: Array[String] = []
var choice_entries: Array[Dictionary] = []
var choice_buttons: Array[Button] = []
var _pending_story_choices: Array = []
var is_typing := false
var typing_generation := 0
var auto_generation := 0


func _ready() -> void:
	auto_button.toggled.connect(_on_auto_button_toggled)
	skip_button.toggled.connect(_on_skip_button_toggled)
	setting_button.pressed.connect(_on_setting_button_pressed)
	text_input_submit_button.pressed.connect(_submit_text_input)
	name_line_edit.text_submitted.connect(_on_name_line_edit_text_submitted)
	$BacklogPanel/BacklogMargin/BacklogLayout/BacklogHeader/BacklogCloseButton.pressed.connect(_close_backlog)
	# Main の静的 Options ノードを取得し、可視状態をボタン表示へ反映します。
	var main_node := get_tree().current_scene
	if main_node != null:
		options_menu = main_node.get_node_or_null("OptionsLayer/Options") as Control
		if options_menu != null:
			options_menu.visibility_changed.connect(_sync_setting_button_state)
		_sync_setting_button_state()


func _input(event: InputEvent) -> void:
	# _input は GUI コントロールより先に呼ばれるため、選択肢表示中もホイール操作を受け取れます。
	if not visible or (options_menu != null and options_menu.visible):
		return
	if event is InputEventMouseButton and event.pressed:
		if backlog_panel.visible and event.button_index == MOUSE_BUTTON_LEFT:
			var mouse_position := get_global_mouse_position()
			var clicked_close_button := backlog_close_button.get_global_rect().has_point(mouse_position)
			var clicked_outside_panel := not backlog_panel.get_global_rect().has_point(mouse_position)
			if clicked_close_button or clicked_outside_panel:
				_close_backlog()
				get_viewport().set_input_as_handled()
				return

		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			backlog_input_blocker.show()
			backlog_panel.show()
			call_deferred("_scroll_backlog_to_latest")
			get_viewport().set_input_as_handled()
		elif (
			event.button_index == MOUSE_BUTTON_WHEEL_DOWN
			and backlog_panel.visible
			and not backlog_panel.get_global_rect().has_point(get_global_mouse_position())
		):
			_close_backlog()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# _unhandled_input は GUI が処理しなかった入力を会話送りに使います。
	if choice_scroll_container.visible or backlog_panel.visible:
		return

	if _is_advance_input(event):
		if is_typing:
			_finish_typing()
		else:
			# Signal は Godot のノード間通知機能です。Ren'Py の進行制御へ次の行を要求します。
			advance_requested.emit()


func show_choices(choices: Array) -> void:
	text_input_container.hide()
	var validated_choices: Array[Dictionary] = []
	for choice_value: Variant in choices:
		if choice_value is Dictionary:
			var choice: Dictionary = choice_value
			if not choice.get("text") is String:
				push_error("選択肢 Dictionary には String 型の text が必要です。")
				return
			validated_choices.append(choice.duplicate(true))
		elif choice_value is String:
			validated_choices.append({"text": choice_value})
		else:
			push_error("選択肢は String または Dictionary で指定してください。")
			return

	if validated_choices.is_empty():
		hide_choices()
		return

	choice_list.show()
	choice_entries = validated_choices
	for choice_index in range(choice_entries.size()):
		var button := _get_or_create_choice_button(choice_index)
		button.text = str(choice_entries[choice_index]["text"])
		button.show()

	for button_index in range(choice_entries.size(), choice_buttons.size()):
		choice_buttons[button_index].hide()

	# ScrollContainer は項目数が画面の高さを超えた場合も選べるようにします。
	choice_scroll_container.scroll_vertical = 0
	choice_scroll_container.show()


func present_story_text(speaker: String, text: String, choices: Array = []) -> void:
	hide_choices()
	speaker_label.text = speaker
	_record_backlog_entry(speaker, text)
	_pending_story_choices = choices.duplicate(true)
	_start_typing(text)
	show()


func present_menu(prompt: String, choices: Array) -> void:
	# Ren'Py の menu prompt は選択肢と同時に表示されるため、入力待ちの開始と同時に選択肢を出します。
	hide_choices()
	speaker_label.text = ""
	_pending_story_choices.clear()
	var menu_history_lines := PackedStringArray()
	if not prompt.is_empty():
		menu_history_lines.append(prompt)
	for choice_value: Variant in choices:
		if choice_value is Dictionary:
			menu_history_lines.append("・" + str(choice_value.get("text", "")))
		elif choice_value is String:
			menu_history_lines.append("・" + choice_value)
	if not menu_history_lines.is_empty():
		_record_backlog_entry("", "\n".join(menu_history_lines))
	_start_typing(prompt)
	show_choices(choices)
	show()


func hide_choices() -> void:
	choice_scroll_container.hide()
	choice_list.hide()
	text_input_container.hide()
	choice_entries.clear()

	for button: Button in choice_buttons:
		button.hide()


func _record_backlog_entry(speaker: String, text: String) -> void:
	var entry := text if speaker.is_empty() else "%s\n%s" % [speaker, text]
	backlog_entries.append(entry)
	backlog_text.text = "\n\n".join(backlog_entries)
	if backlog_panel.visible:
		call_deferred("_scroll_backlog_to_latest")


func _scroll_backlog_to_latest() -> void:
	backlog_scroll.scroll_vertical = int(backlog_scroll.get_v_scroll_bar().max_value)


func _close_backlog() -> void:
	backlog_panel.hide()
	backlog_input_blocker.hide()


func show_text_input(prompt: String, max_length: int = DEFAULT_NAME_INPUT_LENGTH) -> void:
	hide_choices()
	text_input_prompt.text = prompt
	name_line_edit.max_length = clampi(max_length, 1, DEFAULT_NAME_INPUT_LENGTH)
	name_line_edit.clear()
	text_input_validation_label.hide()
	text_input_container.show()
	choice_scroll_container.show()
	name_line_edit.grab_focus()


func show_text_input_error() -> void:
	text_input_validation_label.text = "0〜%d文字で入力してください。日本語・英数字・空白・_・-・ー・中点のみ使用できます。" % name_line_edit.max_length
	text_input_validation_label.show()
	name_line_edit.grab_focus()


func _submit_text_input() -> void:
	var input_value := name_line_edit.text.strip_edges()
	if not _is_safe_name(input_value, name_line_edit.max_length):
		show_text_input_error()
		return

	text_input_submitted.emit(input_value)


func _on_name_line_edit_text_submitted(_submitted_text: String) -> void:
	_submit_text_input()


func _is_safe_name(value: String, max_length: int) -> bool:
	if value.length() > max_length:
		return false

	# RegEx は Godot 組み込み API です。表示や式解釈に危険な記号を許可せず、Unicode の名前文字だけを受け付けます。
	var safe_name_regex := RegEx.new()
	safe_name_regex.compile(SAFE_NAME_PATTERN.replace("10", str(max_length)))
	return safe_name_regex.search(value) != null


func _get_or_create_choice_button(choice_index: int) -> Button:
	if choice_index < choice_buttons.size():
		return choice_buttons[choice_index]

	# 選択肢数に合わせて必要な分だけ作り、次回以降は既存ボタンを再利用します。
	var button := Button.new()
	button.name = "ChoiceButton_%d" % (choice_index + 1)
	button.custom_minimum_size = Vector2(960, 64)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(_on_choice_button_pressed.bind(choice_index))
	choice_list.add_child(button)
	choice_buttons.append(button)
	return button


func _on_choice_button_pressed(choice_index: int) -> void:
	if choice_index < 0 or choice_index >= choice_entries.size():
		return

	var selected_choice: Dictionary = choice_entries[choice_index]
	hide_choices()
	# Signal は Godot のノード間通知機能です。選択結果を進行制御側へ返します。
	choice_selected.emit(choice_index, selected_choice)


func _start_typing(text: String) -> void:
	# visible_characters を増やすことで Label の全文を保持したまま一文字ずつ見せます。
	typing_generation += 1
	var current_generation := typing_generation
	dialogue_label.text = text
	dialogue_label.visible_characters = 0
	is_typing = true

	var character_count := dialogue_label.get_total_character_count()
	if character_count == 0:
		_finish_typing()
		return

	var seconds_per_character := 1.0 / maxf(AudioSettings.characters_per_second, 1.0)
	for character_index in range(1, character_count + 1):
		if _is_skip_active():
			seconds_per_character = 1.0 / SKIP_CHARACTERS_PER_SECOND
		else:
			seconds_per_character = 1.0 / maxf(AudioSettings.characters_per_second, 1.0)

		# SceneTreeTimer はフレーム処理を止めず、指定秒数後に続きを実行します。
		await get_tree().create_timer(seconds_per_character).timeout
		if current_generation != typing_generation:
			return
		dialogue_label.visible_characters = character_index
		# AudioStreamPlayer は Godot の再生ノードです。各文字の表示ごとに待たずにSEを重ねて再生します。
		typing_sound.play()

	is_typing = false
	_show_current_dialogue_choices()
	_continue_while_skipping(current_generation)
	_continue_while_auto(current_generation)


func _finish_typing() -> void:
	# 世代番号を変えて待機中の古いタイマー列を無効化します。
	typing_generation += 1
	dialogue_label.visible_characters = -1
	is_typing = false
	_show_current_dialogue_choices()
	_continue_while_skipping(typing_generation)
	_continue_while_auto(typing_generation)


func _is_skip_active() -> bool:
	# Input.is_key_pressed は Godot の入力 API で、Ctrl を押している間だけ true になります。
	return skip_button.button_pressed or Input.is_key_pressed(KEY_CTRL)


func _continue_while_skipping(completed_generation: int) -> void:
	if not _is_skip_active() or choice_scroll_container.visible or not visible:
		return

	# SceneTreeTimer を短く待つことで、台詞が読める程度の間を残して自動送りします。
	await get_tree().create_timer(SKIP_LINE_DELAY_SECONDS).timeout
	if completed_generation != typing_generation or not _is_skip_active():
		return
	if choice_scroll_container.visible or not visible or is_typing:
		return

	advance_requested.emit()


func _continue_while_auto(completed_generation: int) -> void:
	if _is_skip_active() or not auto_button.button_pressed:
		return
	if choice_scroll_container.visible or not visible:
		return
	if options_menu != null and options_menu.visible:
		return

	# AutoAdvanceSeconds は Options のテキスト設定で調整する台詞間隔です。
	auto_generation += 1
	var current_auto_generation := auto_generation
	await get_tree().create_timer(AudioSettings.auto_advance_seconds).timeout
	if completed_generation != typing_generation or current_auto_generation != auto_generation:
		return
	if not auto_button.button_pressed or _is_skip_active():
		return
	if choice_scroll_container.visible or not visible or is_typing:
		return
	if options_menu != null and options_menu.visible:
		return

	_advance_to_next_text()


func _advance_to_next_text() -> void:
	advance_requested.emit()


func _on_auto_button_toggled(is_enabled: bool) -> void:
	if is_enabled:
		# set_pressed_no_signal は Godot の Button API で、相互排他時の再帰通知を防ぎます。
		skip_button.set_pressed_no_signal(false)
	auto_generation += 1
	if is_enabled and not is_typing:
		_continue_while_auto(typing_generation)


func _on_skip_button_toggled(is_enabled: bool) -> void:
	if is_enabled:
		# AUTO と SKIP を同時に有効にしないよう、反対側のトグルを解除します。
		auto_button.set_pressed_no_signal(false)
	auto_generation += 1
	if is_enabled and not is_typing:
		_continue_while_skipping(typing_generation)


func _on_setting_button_pressed() -> void:
	options_toggle_requested.emit()


func _sync_setting_button_state() -> void:
	if options_menu != null:
		setting_button.set_pressed_no_signal(options_menu.visible)
		if not options_menu.visible and auto_button.button_pressed and not is_typing:
			_continue_while_auto(typing_generation)


func _show_current_dialogue_choices() -> void:
	if not _pending_story_choices.is_empty():
		show_choices(_pending_story_choices)
		_pending_story_choices.clear()


func _is_advance_input(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_accept"):
		return true

	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		return mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT

	return false
