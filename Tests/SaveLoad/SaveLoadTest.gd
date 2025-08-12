extends Control

@onready var btn_qs		: Button = $VBoxContainer/BtnQuickSave
@onready var btn_ql		: Button = $VBoxContainer/BtnQuickLoad
@onready var btn_list	: Button = $VBoxContainer/BtnListSlots
@onready var btn_del	: Button = $VBoxContainer/BtnDeleteQuick
@onready var btn_turn	: Button = $VBoxContainer/BtnEmitTurnEnded
@onready var lbl_log	: Label  = $VBoxContainer/LblLog

func _ready() -> void:
	# Connect buttons
	btn_qs.pressed.connect(_on_quick_save)
	btn_ql.pressed.connect(_on_quick_load)
	btn_list.pressed.connect(_on_list_slots)
	btn_del.pressed.connect(_on_delete_quick)
	btn_turn.pressed.connect(_on_emit_turn_ended)

	# Hook SaveLoadService signals for visual feedback
	if has_node("/root/SaveLoadService"):
		var sls = get_node("/root/SaveLoadService")
		if not sls.is_connected("save_completed", _on_save_completed):
			sls.save_completed.connect(_on_save_completed)
		if not sls.is_connected("load_completed", _on_load_completed):
			sls.load_completed.connect(_on_load_completed)
		if not sls.is_connected("save_failed", _on_save_failed):
			sls.save_failed.connect(_on_save_failed)
		if not sls.is_connected("load_failed", _on_load_failed):
			sls.load_failed.connect(_on_load_failed)

	# Set a known RNG seed up front (so we can prove it round-trips)
	if has_node("/root/SaveLoadService"):
		get_node("/root/SaveLoadService").set_rng_seed(12345)
		_log("Set RNG seed to 12345")

func _on_quick_save() -> void:
	get_node("/root/SaveLoadService").debug_quick_save()

func _on_quick_load() -> void:
	get_node("/root/SaveLoadService").debug_quick_load()

func _on_list_slots() -> void:
	var slots : Array = get_node("/root/SaveLoadService").list_slots()
	_log("Slots: %s" % str(slots))

func _on_delete_quick() -> void:
	var ok : bool = get_node("/root/SaveLoadService").delete_slot("quick")
	_log("Delete 'quick': %s" % (str(ok)))

func _on_emit_turn_ended() -> void:
	# If your EventBus autoload exists with 'event_emitted' or specific signals, try both paths:
	if has_node("/root/EventBus"):
		var bus = get_node("/root/EventBus")
		if bus.has_signal("turn_ended"):
			bus.emit_signal("turn_ended") # direct signal
			_log("Emitted 'turn_ended' signal (direct).")
		elif bus.has_signal("event_emitted"):
			bus.emit_signal("event_emitted", "turn_ended", null) # generic bus
			_log("Emitted 'turn_ended' via generic bus.")
	else:
		_log("No EventBus autoload present; skipping autosave test.")

func _on_save_completed(slot_id : String) -> void:
	_log("save_completed: %s" % slot_id)

func _on_load_completed(slot_id : String) -> void:
	_log("load_completed: %s" % slot_id)
	# Prove the RNG seed survived:
	var seed = get_node("/root/SaveLoadService").get_rng_seed()
	_log("RNG seed after load: %d" % seed)

func _on_save_failed(slot_id : String, reason : String) -> void:
	_log("save_failed: %s (%s)" % [slot_id, reason])

func _on_load_failed(slot_id : String, reason : String) -> void:
	_log("load_failed: %s (%s)" % [slot_id, reason])

func _log(msg : String) -> void:
	lbl_log.text = msg
	print("[SaveLoadTest] %s" % msg)
