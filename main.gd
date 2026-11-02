extends Node2D

## Main シーンの画面制御とオプション表示を担当します。

signal story_event_received(event: Dictionary)
signal story_finished

@onready var dialog: Control = $CanvasLayer/Dialog
@onready var transition_overlay: ColorRect = $CanvasLayer/TransitionOverlay
@onready var options: Control = $OptionsLayer/Options
@onready var story_processor: RenpyStoryProcessor = $StoryProcessor

const RENPY_FADE_HALF_DURATION := 0.5

var json_story_started := false


func _ready() -> void:
	options.close_requested.connect(_close_options)
	# Signal は Godot のノード間通知機能です。ゲーム側はこの Signal からイベントを受け取れます。
	story_processor.event_ready.connect(_on_story_event_ready)
	story_processor.story_finished.connect(_on_story_finished)
	dialog.connect("advance_requested", _on_dialog_advance_requested)
	dialog.connect("choice_selected", _on_dialog_choice_selected)
	dialog.text_input_submitted.connect(_on_dialog_text_input_submitted)
	dialog.options_toggle_requested.connect(_toggle_options)
	if story_processor.load_story():
		start_json_story()


func start_json_story() -> void:
	if json_story_started:
		return
	json_story_started = true
	story_processor.start_story()


func continue_json_story() -> void:
	story_processor.continue_story()


func select_json_story_choice(choice_index: int) -> void:
	story_processor.select_choice(choice_index)


func jump_json_story_to_label(label_name: String) -> void:
	story_processor.jump_to_label(label_name)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_options()
		get_viewport().set_input_as_handled()


func _toggle_options() -> void:
	var should_show_options := not options.visible
	options.visible = should_show_options
	dialog.set_process_unhandled_input(not should_show_options)


func _close_options() -> void:
	options.visible = false
	dialog.set_process_unhandled_input(true)


func _on_story_event_ready(event: Dictionary) -> void:
	var event_type := str(event.get("type", ""))
	var choices_value: Variant = event.get("choices", [])
	if event_type == "dialogue":
		var choices: Array = []
		var speaker_value: Variant = event.get("speaker")
		var speaker := str(speaker_value) if speaker_value is String else ""
		if choices_value is Array:
			choices = choices_value
		# call は Godot の Node API で、JSON 由来の台詞と選択肢を Dialog へ渡します。
		dialog.call(
			"present_story_text",
			speaker,
			str(event.get("text", "")),
			choices
		)
	elif event_type == "menu":
		if choices_value is Array:
			# 選択肢だけの menu も同じ Dialog API で表示します。
			dialog.call("show_choices", choices_value)
	elif event_type == "text_input":
		dialog.call(
			"show_text_input",
			str(event.get("prompt", "")),
			int(event.get("max_length", 10))
		)

	story_event_received.emit(event)
	if event_type == "visual_command":
		await _apply_visual_command(event)
		continue_json_story()


func _apply_visual_command(event: Dictionary) -> void:
	var command_value: Variant = event.get("command", {})
	if not command_value is Dictionary:
		return

	var command: Dictionary = command_value
	if str(command.get("type", "")) == "with" and str(command.get("transition", "")) == "fade":
		await _play_fade_transition()


func _play_fade_transition() -> void:
	# Tween は Godot の SceneTree API です。Ren'Py の fade に合わせ黒へ0.5秒、戻りに0.5秒かけます。
	transition_overlay.modulate.a = 0.0
	transition_overlay.show()

	var fade_to_black: Tween = create_tween()
	fade_to_black.tween_property(
		transition_overlay,
		"modulate:a",
		1.0,
		RENPY_FADE_HALF_DURATION
	)
	await fade_to_black.finished

	var fade_from_black: Tween = create_tween()
	fade_from_black.tween_property(
		transition_overlay,
		"modulate:a",
		0.0,
		RENPY_FADE_HALF_DURATION
	)
	await fade_from_black.finished
	transition_overlay.hide()


func _on_story_finished() -> void:
	dialog.call("hide_choices")
	dialog.hide()
	story_finished.emit()


func _on_dialog_advance_requested() -> void:
	continue_json_story()


func _on_dialog_choice_selected(choice_index: int, _choice: Dictionary) -> void:
	story_processor.select_choice(choice_index)


func _on_dialog_text_input_submitted(value: String) -> void:
	if not story_processor.submit_text_input(value):
		dialog.call("show_text_input_error")
