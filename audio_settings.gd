extends Node

## BGM と SE の音量を管理し、専用 Audio Bus に適用する Autoload です。

const BGM_BUS_NAME := "BGM"
const SE_BUS_NAME := "SE"
const DEFAULT_VOLUME_PERCENT := 50.0
const DEFAULT_CHARACTERS_PER_SECOND := 30.0
const DEFAULT_AUTO_ADVANCE_SECONDS := 2.0

var bgm_volume_percent := DEFAULT_VOLUME_PERCENT
var se_volume_percent := DEFAULT_VOLUME_PERCENT
var characters_per_second := DEFAULT_CHARACTERS_PER_SECOND
var auto_advance_seconds := DEFAULT_AUTO_ADVANCE_SECONDS


func _ready() -> void:
	_apply_bus_volume(BGM_BUS_NAME, bgm_volume_percent)
	_apply_bus_volume(SE_BUS_NAME, se_volume_percent)


func set_bgm_volume_percent(volume_percent: float) -> void:
	bgm_volume_percent = clampf(volume_percent, 0.0, 100.0)
	_apply_bus_volume(BGM_BUS_NAME, bgm_volume_percent)


func set_se_volume_percent(volume_percent: float) -> void:
	se_volume_percent = clampf(volume_percent, 0.0, 100.0)
	_apply_bus_volume(SE_BUS_NAME, se_volume_percent)


func set_characters_per_second(value: float) -> void:
	characters_per_second = clampf(value, 1.0, 120.0)


func set_auto_advance_seconds(value: float) -> void:
	auto_advance_seconds = clampf(value, 0.0, 10.0)


func _apply_bus_volume(bus_name: String, volume_percent: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		push_warning("Audio Bus が見つかりません: %s" % bus_name)
		return

	# AudioServer のバス音量はデシベルで指定するため、0〜100%を線形音量へ変換します。
	var linear_volume := volume_percent / 100.0
	var volume_db := linear_to_db(maxf(linear_volume, 0.0001))
	AudioServer.set_bus_volume_db(bus_index, volume_db)
