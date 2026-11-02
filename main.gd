extends Node2D

## Main シーンの画面制御とオプション表示を担当します。

signal story_event_received(event: Dictionary)
signal story_finished

@onready var dialog: Control = $CanvasLayer/Dialog
@onready var transition_overlay: ColorRect = $CanvasLayer/TransitionOverlay
@onready var background: ColorRect = $Background
@onready var background_texture: TextureRect = $BackgroundTexture
@onready var character_sprite: Sprite2D = $CharacterSprite
@onready var options: Control = $OptionsLayer/Options
@onready var story_processor: RenpyStoryProcessor = $StoryProcessor

const RENPY_FADE_HALF_DURATION := 0.5
const STORY_END_FADE_DURATION := 1.0
const TITLE_SCENE_PATH := "res://title.tscn"
# 画像パスは文字列で保持し、欠落ファイルを preload 時の解析エラーにしないようにします。
const BACKGROUND_TEXTURE_PATHS := {
	"bg 01": "res://Assets/bg 01.png",
	"bg 02": "res://Assets/bg 02.png",
	"bg 03": "res://Assets/bg 03.png",
	"bg 04": "res://Assets/bg 04.png"
}
const CHARACTER_TEXTURE_PATHS := {
	"character 01 common": "res://Assets/character 01 common.png",
	"character 01 relaxing": "res://Assets/character 01 relaxing.png",
	"character 01 surprised": "res://Assets/character 01 surprised.png"
}

var rpy_story_started := false
var is_returning_to_title := false


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
		start_rpy_story()


func start_rpy_story() -> void:
	if rpy_story_started:
		return
	rpy_story_started = true
	story_processor.start_story()


func continue_rpy_story() -> void:
	story_processor.continue_story()


func select_rpy_story_choice(choice_index: int) -> void:
	story_processor.select_choice(choice_index)


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
		# call は Godot の Node API で、script.rpy 由来の台詞と選択肢を Dialog へ渡します。
		dialog.call(
			"present_story_text",
			speaker,
			str(event.get("text", "")),
			choices
		)
	elif event_type == "menu":
		if choices_value is Array:
			var prompt := str(event.get("prompt", ""))
			if prompt.is_empty():
				dialog.call("show_choices", choices_value)
			else:
				# Ren'Py と同様に、menu の説明文と選択肢を同時に表示します。
				dialog.call("present_menu", prompt, choices_value)
	elif event_type == "text_input":
		dialog.call(
			"show_text_input",
			str(event.get("prompt", "")),
			int(event.get("max_length", 10))
		)

	story_event_received.emit(event)
	if event_type == "visual_command":
		await _apply_visual_command(event)
		continue_rpy_story()


func _apply_visual_command(event: Dictionary) -> void:
	var command := str(event.get("command", ""))
	if command == "with fade":
		await _play_fade_transition()
	elif command.begins_with("scene "):
		_show_background(command.trim_prefix("scene ").strip_edges())
	elif command.begins_with("show "):
		_show_character(command, float(event.get("zoom", 0.0)))
	elif command.begins_with("hide ") and command.trim_prefix("hide ").begins_with("character"):
		character_sprite.hide()


func _show_background(image_name: String) -> void:
	character_sprite.hide()
	background_texture.hide()
	background.color = Color.BLACK
	background.show()
	if image_name == "black":
		return

	var texture := _load_optional_texture(BACKGROUND_TEXTURE_PATHS, image_name, "背景")
	if texture == null:
		return

	background_texture.texture = texture
	background_texture.show()
	background.hide()


func _show_character(command: String, zoom: float) -> void:
	var image_end := command.find(" at ")
	var image_name := command.trim_prefix("show ")
	if image_end >= 0:
		image_name = command.substr("show ".length(), image_end - "show ".length())
	var texture := _load_optional_texture(CHARACTER_TEXTURE_PATHS, image_name, "キャラクター")
	if texture == null:
		character_sprite.hide()
		return

	var was_visible := character_sprite.visible
	# Sprite2D は Godot の 2D 描画ノードです。Ren'Py の image tag と Position をここへ反映します。
	character_sprite.texture = texture
	if zoom > 0.0:
		character_sprite.scale = Vector2.ONE * zoom
	if image_end >= 0:
		_set_character_position(command, texture)
	elif not was_visible:
		_center_character_at_bottom(texture)
	character_sprite.show()


func _load_optional_texture(texture_paths: Dictionary, image_name: String, image_type: String) -> Texture2D:
	var path_value: Variant = texture_paths.get(image_name)
	if not path_value is String:
		push_warning("%s画像の登録がありません: %s" % [image_type, image_name])
		return null

	var texture_path := str(path_value)
	# FileAccess と ResourceLoader は Godot API です。画像が欠落しても警告に留めてシナリオを続けます。
	if not FileAccess.file_exists(texture_path):
		push_warning("%s画像が見つかりません。画像表示を省略します: %s" % [image_type, texture_path])
		return null

	var loaded_resource: Resource = ResourceLoader.load(texture_path)
	if loaded_resource is Texture2D:
		return loaded_resource as Texture2D

	push_warning("%s画像を読み込めません。画像表示を省略します: %s" % [image_type, texture_path])
	return null


func _center_character_at_bottom(texture: Texture2D) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var displayed_size := Vector2(texture.get_size()) * character_sprite.scale
	character_sprite.position = Vector2(
		(viewport_size.x - displayed_size.x) * 0.5,
		viewport_size.y - displayed_size.y
	)


func _set_character_position(command: String, texture: Texture2D) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var texture_size := Vector2(texture.get_size()) * character_sprite.scale
	var x_anchor := _read_position_value(command, "xanchor", 0.5)
	var y_anchor := _read_position_value(command, "yanchor", 1.0)
	var x_position := _read_position_value(command, "xpos", 0.5)
	var y_position := _read_position_value(command, "ypos", 1.0)
	character_sprite.position = Vector2(
		viewport_size.x * x_position - texture_size.x * x_anchor,
		viewport_size.y * y_position - texture_size.y * y_anchor
	)


func _read_position_value(command: String, property_name: String, fallback: float) -> float:
	var property_regex := RegEx.new()
	property_regex.compile(property_name + "\\s*=\\s*(-?(?:\\d+\\.?\\d*|\\.\\d+))")
	var property_match := property_regex.search(command)
	if property_match == null:
		return fallback
	return float(property_match.get_string(1))


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
	if is_returning_to_title:
		return
	is_returning_to_title = true

	dialog.call("hide_choices")
	dialog.hide()
	options.hide()
	dialog.set_process_unhandled_input(false)

	transition_overlay.modulate.a = 0.0
	transition_overlay.show()
	# Tween は Godot のアニメーション機能です。シナリオ終了時に1秒かけて黒へフェードします。
	var fade_to_black: Tween = create_tween()
	fade_to_black.tween_property(
		transition_overlay,
		"modulate:a",
		1.0,
		STORY_END_FADE_DURATION
	)
	await fade_to_black.finished

	story_finished.emit()
	var result: Error = get_tree().change_scene_to_file(TITLE_SCENE_PATH)
	if result != OK:
		push_error("Title シーンへの遷移に失敗しました: %s" % TITLE_SCENE_PATH)


func _on_dialog_advance_requested() -> void:
	continue_rpy_story()


func _on_dialog_choice_selected(choice_index: int, _choice: Dictionary) -> void:
	story_processor.select_choice(choice_index)


func _on_dialog_text_input_submitted(value: String) -> void:
	if not story_processor.submit_text_input(value):
		dialog.call("show_text_input_error")
