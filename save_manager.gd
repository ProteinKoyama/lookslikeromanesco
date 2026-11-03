extends Node

## ブラウザとデスクトップの保存先を切り替え、固定数のセーブスロットを管理します。

const SLOT_COUNT := 3
const STORAGE_KEY := "look_likes_romanesco_save_slots_v1"
const DESKTOP_SAVE_PATH := "user://look_likes_romanesco_save_slots.json"

var _slots: Array = []
var _pending_load_slot := -1


func _ready() -> void:
	_slots.resize(SLOT_COUNT)
	_load_persisted_slots()


func get_slot_summaries() -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	for slot_index in range(SLOT_COUNT):
		var record := _get_record(slot_index)
		if record.is_empty():
			summaries.append({"occupied": false, "slot_index": slot_index})
			continue

		var event_value: Variant = record.get("current_event", {})
		var preview := ""
		if event_value is Dictionary:
			preview = str(event_value.get("text", event_value.get("prompt", "")))
		if preview.length() > 64:
			preview = preview.substr(0, 64) + "…"
		summaries.append({
			"occupied": true,
			"slot_index": slot_index,
			"saved_at": str(record.get("saved_at", "")),
			"preview": preview
		})
	return summaries


func save_slot(slot_index: int, save_data: Dictionary) -> bool:
	if not _is_valid_slot(slot_index) or save_data.is_empty():
		return false

	var previous_record: Variant = _slots[slot_index]
	var new_record := save_data.duplicate(true)
	new_record["saved_at"] = Time.get_datetime_string_from_system(false, true)
	_slots[slot_index] = new_record
	if _persist_slots():
		return true

	_slots[slot_index] = previous_record
	return false


func load_slot(slot_index: int) -> Dictionary:
	return _get_record(slot_index)


func has_slot(slot_index: int) -> bool:
	return not _get_record(slot_index).is_empty()


func delete_slot(slot_index: int) -> bool:
	if not _is_valid_slot(slot_index) or not has_slot(slot_index):
		return false

	var previous_record: Variant = _slots[slot_index]
	_slots[slot_index] = null
	if _persist_slots():
		return true

	_slots[slot_index] = previous_record
	return false


func set_pending_load_slot(slot_index: int) -> void:
	_pending_load_slot = slot_index if has_slot(slot_index) else -1


func take_pending_load_slot() -> int:
	var slot_index := _pending_load_slot
	_pending_load_slot = -1
	return slot_index


func _get_record(slot_index: int) -> Dictionary:
	if not _is_valid_slot(slot_index):
		return {}
	var record: Variant = _slots[slot_index]
	return record.duplicate(true) if record is Dictionary else {}


func _is_valid_slot(slot_index: int) -> bool:
	return slot_index >= 0 and slot_index < SLOT_COUNT


func _load_persisted_slots() -> void:
	var stored_text := ""
	if OS.has_feature("web"):
		# JavaScriptBridge は Godot Web Export からブラウザの localStorage を使う API です。
		var browser_value: Variant = JavaScriptBridge.eval(
			"(() => { try { return window.localStorage.getItem(%s) || ''; } catch (e) { return ''; } })()"
			% JSON.stringify(STORAGE_KEY)
		)
		if browser_value is String:
			stored_text = browser_value
	else:
		if not FileAccess.file_exists(DESKTOP_SAVE_PATH):
			return
		var file := FileAccess.open(DESKTOP_SAVE_PATH, FileAccess.READ)
		if file == null:
			push_warning("セーブデータを読み込めませんでした。")
			return
		stored_text = file.get_as_text()

	if stored_text.is_empty():
		return
	var parsed_value: Variant = JSON.parse_string(stored_text)
	if not parsed_value is Dictionary:
		push_warning("セーブデータの形式が正しくありません。")
		return
	var stored_slots: Variant = parsed_value.get("slots", [])
	if not stored_slots is Array:
		push_warning("セーブスロットのデータが正しくありません。")
		return
	for slot_index in range(mini(SLOT_COUNT, stored_slots.size())):
		if stored_slots[slot_index] is Dictionary:
			_slots[slot_index] = stored_slots[slot_index].duplicate(true)


func _persist_slots() -> bool:
	var serialized_slots := JSON.stringify({"slots": _slots})
	if OS.has_feature("web"):
		# JSON.stringify で値を文字列エスケープし、コードとして解釈されない形で保存します。
		var javascript := (
			"(() => { try { window.localStorage.setItem(%s, %s); return true; } catch (e) { return false; } })()"
			% [JSON.stringify(STORAGE_KEY), JSON.stringify(serialized_slots)]
		)
		var save_result: Variant = JavaScriptBridge.eval(javascript)
		return save_result is bool and save_result

	var file := FileAccess.open(DESKTOP_SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("セーブ先を開けませんでした: %s" % DESKTOP_SAVE_PATH)
		return false
	file.store_string(serialized_slots)
	return true
