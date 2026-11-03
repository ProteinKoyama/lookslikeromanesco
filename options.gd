extends Control

## オプション画面のタブ切り替えだけを担当します。

signal close_requested
signal save_requested(slot_index: int)
signal load_requested(slot_index: int)

const TITLE_SCENE_PATH := "res://title.tscn"

@onready var tab_container: TabContainer = $Frame/Margin/Tabs
@onready var to_title_button: Button = $"Frame/Margin/Tabs/ゲーム終了/VBoxContainer/ToTitleButton"
@onready var quit_button:Button = $"Frame/Margin/Tabs/ゲーム終了/VBoxContainer/QuitButton"
@onready var close_button:Button = $CloseButton
@onready var se_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/SESlider
@onready var se_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/SELabel
@onready var characters_per_second_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/CharactersPerSecondSlider
@onready var auto_advance_seconds_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/AutoAdvanceSecondsSlider
@onready var characters_per_second_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/CharactersPerSecondLabel
@onready var auto_advance_seconds_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/AutoAdvanceSecondsLabel

func _ready() -> void:
	to_title_button.pressed.connect(_return_to_title)
	quit_button.pressed.connect(_on_quit_button_pressed)
	_connect_save_slot_buttons()
	_setup_audio_controls()
	_setup_text_controls()


func _setup_audio_controls() -> void:
	se_slider.value = AudioSettings.se_volume_percent
	_update_se_volume(se_slider.value)
	se_slider.value_changed.connect(_update_se_volume)


func _update_se_volume(volume_percent: float) -> void:
	AudioSettings.set_se_volume_percent(volume_percent)
	se_label.text = "SE 音量: %d" % roundi(volume_percent)


func _setup_text_controls() -> void:
	characters_per_second_slider.value = AudioSettings.characters_per_second
	auto_advance_seconds_slider.value = AudioSettings.auto_advance_seconds
	_update_characters_per_second(characters_per_second_slider.value)
	_update_auto_advance_seconds(auto_advance_seconds_slider.value)
	characters_per_second_slider.value_changed.connect(_update_characters_per_second)
	auto_advance_seconds_slider.value_changed.connect(_update_auto_advance_seconds)


func _connect_save_slot_buttons() -> void:
	for slot_index in range(3):
		var slot_number := slot_index + 1
		var save_button := get_node(
			"Frame/Margin/Tabs/セーブ/SaveSlot%dRow/SaveSlot%dButton" % [slot_number, slot_number]
		) as Button
		var load_button := get_node(
			"Frame/Margin/Tabs/ロード/LoadSlot%dRow/LoadSlot%dButton" % [slot_number, slot_number]
		) as Button
		save_button.pressed.connect(_on_save_slot_pressed.bind(slot_index))
		load_button.pressed.connect(_on_load_slot_pressed.bind(slot_index))


func _on_save_slot_pressed(slot_index: int) -> void:
	save_requested.emit(slot_index)


func _on_load_slot_pressed(slot_index: int) -> void:
	load_requested.emit(slot_index)


func _update_characters_per_second(value: float) -> void:
	AudioSettings.set_characters_per_second(value)
	characters_per_second_label.text = "文字送り速度: %d 文字/秒" % roundi(value)


func _update_auto_advance_seconds(value: float) -> void:
	AudioSettings.set_auto_advance_seconds(value)
	auto_advance_seconds_label.text = "オートモード送り速度: %.1f 秒" % value


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_requested.emit()
		get_viewport().set_input_as_handled()


func select_tab(tab_index: int) -> void:
	if tab_index >= 0 and tab_index < tab_container.get_tab_count():
		tab_container.current_tab = tab_index


func update_save_slots(summaries: Array) -> void:
	for slot_index in range(3):
		var summary: Dictionary = summaries[slot_index] if slot_index < summaries.size() else {}
		var is_occupied := bool(summary.get("occupied", false))
		var slot_number := slot_index + 1
		var save_label := get_node("Frame/Margin/Tabs/セーブ/SaveSlot%dRow/SaveSlot%dLabel" % [slot_number, slot_number]) as Label
		var load_label := get_node("Frame/Margin/Tabs/ロード/LoadSlot%dRow/LoadSlot%dLabel" % [slot_number, slot_number]) as Label
		var load_button := get_node("Frame/Margin/Tabs/ロード/LoadSlot%dRow/LoadSlot%dButton" % [slot_number, slot_number]) as Button
		if not is_occupied:
			save_label.text = "スロット%d: 空き" % slot_number
			load_label.text = save_label.text
			load_button.disabled = true
			continue

		var slot_description := "スロット%d\n%s\n%s" % [
			slot_number,
			str(summary.get("saved_at", "")),
			str(summary.get("preview", ""))
		]
		save_label.text = slot_description
		load_label.text = slot_description
		load_button.disabled = false


func set_save_status(message: String) -> void:
	$Frame/Margin/Tabs/セーブ/SaveStatusLabel.text = message


func set_load_status(message: String) -> void:
	$Frame/Margin/Tabs/ロード/LoadStatusLabel.text = message


func open_from_title(tab_name: String) -> void:
	# タイトル画面から開く場合は、ゲーム中専用のタブを隠します。
	_hide_tab_by_name("セーブ")
	_hide_tab_by_name("ゲーム終了")

	var requested_tab_index := _find_tab_index(tab_name)
	if requested_tab_index >= 0:
		tab_container.current_tab = requested_tab_index


func show_popup() -> void:
	visible = true


func hide_popup() -> void:
	visible = false


func _hide_tab_by_name(tab_name: String) -> void:
	var tab_index := _find_tab_index(tab_name)
	if tab_index >= 0:
		tab_container.set_tab_hidden(tab_index, true)


func _find_tab_index(tab_name: String) -> int:
	for tab_index in range(tab_container.get_tab_count()):
		if tab_container.get_tab_title(tab_index) == tab_name:
			return tab_index

	return -1


func _return_to_title() -> void:
	# SceneTree にメインシーンの切り替えを依頼します。
	var result: Error = get_tree().change_scene_to_file(TITLE_SCENE_PATH)
	if result != OK:
		push_error("Title シーンへの遷移に失敗しました: %s" % TITLE_SCENE_PATH)

func _on_quit_button_pressed() -> void:
	# SceneTree.quit() は実行中のゲームを終了する Godot の API です。
	get_tree().quit()


func _on_close_button_pressed() -> void:
	if visible:
		close_requested.emit()
		get_viewport().set_input_as_handled()
