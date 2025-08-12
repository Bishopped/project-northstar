## res://_test/ModifierSystemTest.gd
extends Node

var _unit_id : String = "hero1"

func _ready() -> void:
	# Subscribe to EventBus prints for visibility (shape-agnostic).
	if typeof(EventBus) != TYPE_NIL:
		# Try to connect if there is a signal; otherwise rely on debug prints inside EventBus.
		if EventBus.has_signal("modifier_changed"):
			EventBus.connect("modifier_changed", Callable(self, "_on_modifier_changed"))
		if EventBus.has_signal("modifiers_cleared"):
			EventBus.connect("modifiers_cleared", Callable(self, "_on_modifiers_cleared"))

	# Apply demo set
	ModifierSystem.debug_apply_demo_set(_unit_id)

	# Query initial values
	_print_snapshot("Initial")

	# Remove one source
	var removed : bool = ModifierSystem.remove_modifier(_unit_id, "attack_bonus", "hex_penalty_example")
	print("[Test] Removed hex_penalty_example? ", removed)
	_print_snapshot("After removing hex penalty")

	# Advance time: 6 seconds to test time-based expiry (Shield of Faith is 600s, won't expire; Faerie Fire is rounds-based)
	ModifierSystem.tick_durations(6.0, false)
	_print_snapshot("After 6s tick")

	# Advance a round to reduce Faerie Fire duration
	ModifierSystem.tick_durations(0.0, true)
	_print_snapshot("After 1 combat round")

	# Clear unit to test cleared event
	ModifierSystem.clear_unit(_unit_id)
	print("[Test] Cleared unit")

func _print_snapshot(label : String) -> void:
	var atk_total : float = ModifierSystem.get_total(_unit_id, "attack_bonus", 0.0)
	var ac_total  : float = ModifierSystem.get_total(_unit_id, "ac_bonus", 0.0)
	var adv      : int   = ModifierSystem.get_advantage(_unit_id, "attack")
	var fire_res : bool  = ModifierSystem.has_resistance(_unit_id, "fire")

	print("\n=== ", label, " ===")
	print("attack_bonus: ", atk_total)
	print("ac_bonus:     ", ac_total)
	print("advantage:atk:", adv)
	print("resistance:fire:", fire_res)

func _on_modifier_changed(unit_id : String, key : String) -> void:
	print("[EventBus] modifier_changed: ", unit_id, " :: ", key)

func _on_modifiers_cleared(unit_id : String) -> void:
	print("[EventBus] modifiers_cleared: ", unit_id)
