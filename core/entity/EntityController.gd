# res://Runtime/Entity/EntityController.gd
# Key integration points for StatBlock.
# Assumes you already have: unit_id:String, team:String, and references to CharacterSheet & EquipmentState.
# Links to vault notes:
# - [[Runtime/StatBlock]]
# - [[Managers/UnitRoster]] (entities present there should expose coherent queries)
# - [[Managers/EventBus]], [[Systems/ModifierSystem]], [[Managers/ConditionManager]]

extends Node

# Identity
@export var unit_id: String = ""
@export var team: String = "neutral"

# Data providers (replace with your actual fields/getters)
var character_sheet: Dictionary = {}   # from [[Runtime/CharacterSheet]]
var equipment_state: Dictionary = {}   # from [[Runtime/EquipmentState]]
var condition_ids: Array = []          # active condition ids from [[Managers/ConditionManager]]

# Cached derived stats
var _stat_block: Dictionary = {}       # always a safe dictionary

# Cached services
var _event_bus: Node = null

func _ready() -> void:
	# Resolve EventBus (best-effort)
	var _event_bus = get_node("/root/EventBus") if has_node("/root/EventBus") else null

	# Subscribe to relevant events (guard if null)
	if _event_bus != null:
		# Conditions
		if _event_bus.has_signal("condition_applied"):
			_event_bus.connect("condition_applied", Callable(self, "_on_condition_applied"))
		if _event_bus.has_signal("condition_removed"):
			_event_bus.connect("condition_removed", Callable(self, "_on_condition_removed"))
		# Equipment
		if _event_bus.has_signal("equipped"):
			_event_bus.connect("equipped", Callable(self, "_on_equipped"))
		if _event_bus.has_signal("unequipped"):
			_event_bus.connect("unequipped", Callable(self, "_on_unequipped"))
		# Level up
		if _event_bus.has_signal("levelup_complete"):
			_event_bus.connect("levelup_complete", Callable(self, "_on_levelup_complete"))
		# Modifiers changed (from [[Systems/ModifierSystem]])
		if _event_bus.has_signal("modifier_changed"):
			_event_bus.connect("modifier_changed", Callable(self, "_on_modifier_changed"))

	# Initial build
	rebuild_stat_block()


func rebuild_stat_block() -> void:
	# Build a fresh stat block from current inputs
	_stat_block = StatBlock.build(unit_id, character_sheet, equipment_state, condition_ids)


# ---------------- Public queries (helpers for other systems) ----------------

func get_stat_block() -> Dictionary:
	# Always return a dictionary
	return _stat_block if _stat_block != null else {}


func get_ac() -> int:
	return StatBlock.get_ac(unit_id, get_stat_block())


func get_speed() -> float:
	return StatBlock.get_speed(unit_id, get_stat_block())


func get_save(ability: String) -> int:
	return StatBlock.get_save(get_stat_block(), ability)


# ---------------- Event handlers that trigger rebuilds ----------------

func _on_condition_applied(e_unit_id: String, condition_id: String) -> void:
	if e_unit_id == unit_id:
		# Keep local list if you store them here; or fetch from ConditionManager before rebuild
		if not condition_ids.has(condition_id):
			condition_ids.append(condition_id)
		rebuild_stat_block()

func _on_condition_removed(e_unit_id: String, condition_id: String) -> void:
	if e_unit_id == unit_id:
		condition_ids.erase(condition_id)
		rebuild_stat_block()

func _on_equipped(e_unit_id: String, item_id: String, slot: String) -> void:
	if e_unit_id == unit_id:
		# Update local equipment_state minimalistically
		if equipment_state == null:
			equipment_state = {}
		equipment_state[slot] = item_id
		rebuild_stat_block()

func _on_unequipped(e_unit_id: String, slot: String) -> void:
	if e_unit_id == unit_id:
		if equipment_state == null:
			equipment_state = {}
		equipment_state.erase(slot)
		rebuild_stat_block()

func _on_levelup_complete(e_unit_id: String) -> void:
	if e_unit_id == unit_id:
		# Your CharacterSheet should already reflect the new level before this is fired
		rebuild_stat_block()

func _on_modifier_changed(e_unit_id: String, key: String) -> void:
	if e_unit_id == unit_id:
		rebuild_stat_block()
