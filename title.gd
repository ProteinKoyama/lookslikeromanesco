extends Node

## ライセンス画面の表示だけを担当します。
## ポップアップの見た目とノード構造は title.tscn で管理します。

const MAIN_SCENE_PATH := "res://main.tscn"

# onready はシーンツリーが構築された後に、静的ノードへの参照を取得します。
@onready var license_button: Button = $MenuButtons/LicenseButton
@onready var license_popup: Window = $LicensePopup
@onready var license_text: RichTextLabel = $LicensePopup/Panel/Margin/Layout/LicenseText
@onready var close_button: Button = $LicensePopup/Panel/Margin/Layout/CloseButton
@onready var start_button: Button = $MenuButtons/StartButton
@onready var load_button: Button = $MenuButtons/LoadButton
@onready var setting_button: Button = $MenuButtons/SettingButton
@onready var quit_button: Button = $MenuButtons/QuitButton
@onready var options_popup: Control = $OptionsLayer/Options


func _ready() -> void:
	license_button.pressed.connect(_show_license_popup)
	close_button.pressed.connect(_hide_license_popup)
	license_popup.close_requested.connect(_hide_license_popup)
	start_button.pressed.connect(_on_start_button_pressed)
	load_button.pressed.connect(_on_load_button_pressed)
	setting_button.pressed.connect(_on_setting_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	options_popup.close_requested.connect(_close_options_popup)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and options_popup.visible:
		_close_options_popup()
		get_viewport().set_input_as_handled()


func _show_license_popup() -> void:
	# Engine シングルトンから実行中の Godot のライセンス本文を取得します。
	license_text.text = Engine.get_license_text()
	license_popup.popup_centered()


func _hide_license_popup() -> void:
	license_popup.hide()


func _on_start_button_pressed() -> void:
	# SceneTree を使い、ホーム画面からゲーム本編のシーンへ切り替えます。
	var result: Error = get_tree().change_scene_to_file(MAIN_SCENE_PATH)
	if result != OK:
		push_error("Main シーンへの遷移に失敗しました: %s" % MAIN_SCENE_PATH)


func _on_quit_button_pressed() -> void:
	# SceneTree.quit() は実行中のゲームを終了する Godot の API です。
	get_tree().quit()


func _on_load_button_pressed() -> void:
	_open_options_tab("ロード")


func _on_setting_button_pressed() -> void:
	_open_options_tab("設定")


func _open_options_tab(tab_name: String) -> void:
	options_popup.open_from_title(tab_name)
	options_popup.show_popup()


func _close_options_popup() -> void:
	options_popup.hide()
