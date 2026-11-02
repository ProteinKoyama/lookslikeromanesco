extends Control

## オプション画面のタブ切り替えだけを担当します。

signal close_requested

const TITLE_SCENE_PATH := "res://title.tscn"

@onready var tab_container: TabContainer = $Frame/Margin/Tabs
@onready var to_title_button: Button = $"Frame/Margin/Tabs/ゲーム終了/VBoxContainer/ToTitleButton"
@onready var quit_button:Button = $"Frame/Margin/Tabs/ゲーム終了/VBoxContainer/QuitButton"
@onready var close_button:Button = $CloseButton
@onready var bgm_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/BGMSlider
@onready var se_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/SESlider
@onready var bgm_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/BGMLabel
@onready var se_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/SoundVBoxContainer/SELabel
@onready var characters_per_second_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/CharactersPerSecondSlider
@onready var auto_advance_seconds_slider: HSlider = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/AutoAdvanceSecondsSlider
@onready var characters_per_second_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/CharactersPerSecondLabel
@onready var auto_advance_seconds_label: Label = $Frame/Margin/Tabs/設定/OptionsHBoxContainer/TextVBoxContainer/AutoAdvanceSecondsLabel

func _ready() -> void:
	to_title_button.pressed.connect(_return_to_title)
	quit_button.pressed.connect(_on_quit_button_pressed)
	_setup_audio_controls()
	_setup_text_controls()


func _setup_audio_controls() -> void:
	bgm_slider.value = AudioSettings.bgm_volume_percent
	se_slider.value = AudioSettings.se_volume_percent
	_update_bgm_volume(bgm_slider.value)
	_update_se_volume(se_slider.value)
	bgm_slider.value_changed.connect(_update_bgm_volume)
	se_slider.value_changed.connect(_update_se_volume)


func _update_bgm_volume(volume_percent: float) -> void:
	AudioSettings.set_bgm_volume_percent(volume_percent)
	bgm_label.text = "BGM 音量: %d" % roundi(volume_percent)


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
