extends Node3D
# File: res://core/entity/EntityController.gd
# Purpose: Bridges CharacterSheet -> StatBlock -> CombatantState for a single in-world unit.
# Links: Managers/UnitRoster.md, Managers/EventBus.md, Runtime/CombatantState.md,
#        Runtime/CharacterSheet.md, Runtime/StatBlock.md, Systems/MovementController.md

@export var unit_id: String = "unit_??"          # Exposed so designers/tests can pin IDs
@export var team: String = "neutral"             # "party" | "enemy" | etc., safe default

# Base character data. In the vault this may be a resource; we allow Dictionary or Resource ref.
var character_sheet: Variant = {}                # Dictionary or a typed Resource; safe default {}
# Runtime mutable state; align with Runtime/CombatantState.md (HP, tempHP, conditions, etc.)
var combatant_state: Dictionary = {
	"hp": 1,                                     # safe, non-zero
	"temp_hp": 0,
	"conditions": [],                            # array of condition IDs
	"resources": {},                             # e.g., slots, ki, rage
	"reaction_available": true,                  # action economy flag
}
# Derived numbers cache; align with Runtime/StatBlock.md. Rebuilt via rebuild_stat_block().
var stat_block: Dictionary = {
	"ac": 10,                                    # safe flat AC
	"speed": 6.0,                                # meters/tiles per vault rules; safe default
	"senses": { "passive_perception": 10 },      # safe baseline
	"actions": [],                               # list of action IDs or descriptors
}

# Node refs used by MovementController later (we host them but don't pathfind here).
@onready var nav: NavigationAgent3D = $NavAgent
@onready var body: CharacterBody3D = $Body
@onready var visual_model: Node3D = $VisualModel

func _ready() -> void:
	# Ensure we have a usable unique ID for registration & events.
	if unit_id == "" or unit_id == "unit_??":
		unit_id = _generate_unit_id()

	# Register with UnitRoster (autoload expected). Pass the NODE (self), not strings.
	if _has_autoload("UnitRoster"):
		UnitRoster.register_unit(self)

	# Announce spawn (UnitRoster also listens via EventBus).
	_emit_event_safe("entity_spawned", [unit_id])

	# Build initial derived stats.
	rebuild_stat_block()

	# Subscribe to condition changes via EventBus (if signals exist).
	_connect_eventbus_signal("condition_applied", _on_condition_applied)
	_connect_eventbus_signal("condition_removed", _on_condition_removed)


func _exit_tree() -> void:
	# Log so we can see this actually runs
	print("[EntityController] _exit_tree:", unit_id)

	# Primary: publish via EventBus
	_emit_event_safe("entity_despawned", [unit_id])

	# Synchronous fallback: unregister directly (no await!)
	if has_node("/root/UnitRoster") and UnitRoster.exists(unit_id):
		print("[EntityController] Fallback unregister for:", unit_id)
		UnitRoster.unregister_unit(unit_id)

# -----------------------
# Public Query API (minimum)
# -----------------------
func get_stat_block() -> Dictionary:
	return stat_block

func get_combatant_state() -> Dictionary:
	return combatant_state

func get_character_sheet() -> Variant:
	return character_sheet

func has_reaction_available() -> bool:
	# Stub: reads from combatant_state; future systems (TurnManager) may also gate this.
	return bool(combatant_state.get("reaction_available", true))

func get_speed() -> float:
	# Falls back to a safe default if derived value is missing.
	return float(stat_block.get("speed", 6.0))

func get_ac() -> int:
	# Stub: later this will consult ArmorClassService if present.
	return int(stat_block.get("ac", 10))


# -----------------------
# Derived Stat Rebuild
# -----------------------
func rebuild_stat_block() -> void:
	# Build a base stat block from the character_sheet.
	var base: Dictionary = _build_base_stat_block()
	# Apply conditions and modifiers (via ModifierSystem) if available.
	base = _apply_conditions_to_stat_block(base)
	base = _apply_modifier_system(base)
	# Cache.
	stat_block = base


# -----------------------
# Movement host helpers (MovementController will call these)
# -----------------------
func teleport_to(global_pos: Vector3) -> void:
	# Teleport without pathing; MovementController can emit entity_moved.
	if body:
		var prev: Vector3 = global_transform.origin
		global_transform.origin = global_pos
		# Optionally keep Body velocity zeroed to avoid physics drift.
		if "velocity" in body:
			body.velocity = Vector3.ZERO
		# Let others know we moved (MovementController may also do this explicitly).
		_emit_event_safe("entity_moved", [unit_id, prev, global_pos])

func set_facing(direction: Vector3) -> void:
	# Rotate the visual around Y to face 'direction' if non-zero.
	var dir: Vector3 = direction
	if dir.length() < 0.0001:
		return
	var flat: Vector3 = Vector3(dir.x, 0.0, dir.z).normalized()
	var target_yaw: float = atan2(flat.x, flat.z)
	if visual_model:
		var basis := visual_model.global_transform.basis
		visual_model.global_transform = Transform3D(Basis(Vector3.UP, target_yaw), visual_model.global_transform.origin)


# -----------------------
# EventBus listeners
# -----------------------
func _on_condition_applied(ev_unit_id: String, condition_id: String) -> void:
	if ev_unit_id == unit_id:
		rebuild_stat_block()

func _on_condition_removed(ev_unit_id: String, condition_id: String) -> void:
	if ev_unit_id == unit_id:
		rebuild_stat_block()


# -----------------------
# Internal helpers
# -----------------------
func _generate_unit_id() -> String:
	# Simple unique-ish ID; OK for editor/runtime use. Replace with UUID if you add that plugin.
	var t: int = Time.get_ticks_msec()
	var r: int = randi()
	return "unit_%d_%d" % [t, r]

func _build_base_stat_block() -> Dictionary:
	# Pulls minimal fields from character_sheet or uses safe defaults.
	# Expected fields per Runtime/StatBlock.md: ac, speed, senses, actions (at minimum).
	var base: Dictionary = {
		"ac": 10,
		"speed": 6.0,
		"senses": { "passive_perception": 10 },
		"actions": []
	}
	if typeof(character_sheet) == TYPE_DICTIONARY:
		base["ac"] = int(character_sheet.get("base_ac", base["ac"]))
		base["speed"] = float(character_sheet.get("base_speed", base["speed"]))
		if character_sheet.has("senses") and typeof(character_sheet["senses"]) == TYPE_DICTIONARY:
			base["senses"] = character_sheet["senses"]
		if character_sheet.has("actions") and typeof(character_sheet["actions"]) == TYPE_ARRAY:
			base["actions"] = character_sheet["actions"]
	# If character_sheet is a Resource, you can fetch properties similarly with get().
	return base

func _apply_conditions_to_stat_block(base: Dictionary) -> Dictionary:
	# Read combatant_state.conditions and apply simple, safe adjustments as placeholder.
	# Real logic will live in ModifierSystem + condition effects per Systems/ModifierSystem.md.
	var out: Dictionary = base.duplicate(true)
	var conditions: Array = combatant_state.get("conditions", [])
	# Example stub: "restrained" could set speed to 0 (purely for smoke test; replace later).
	if "restrained" in conditions:
		out["speed"] = 0.0
	return out

func _apply_modifier_system(base: Dictionary) -> Dictionary:
	# If ModifierSystem exists, let it transform the stat block. Otherwise return base.
	if _has_autoload("ModifierSystem") and _has_method(ModifierSystem, "apply_to_stat_block"):
		# Convention: apply_to_stat_block(unit_id, in_block:Dictionary) -> Dictionary
		var transformed: Variant = ModifierSystem.apply_to_stat_block(unit_id, base)
		if typeof(transformed) == TYPE_DICTIONARY:
			return transformed
	return base

func _connect_eventbus_signal(signal_name: String, callable_target: Callable) -> void:
	if _has_autoload("EventBus") and EventBus.has_signal(signal_name):
		EventBus.connect(signal_name, callable_target)

func _emit_event_safe(signal_name: String, args: Array) -> void:
	if _has_autoload("EventBus"):
		# Prefer emit_signal if the signal exists; otherwise fall back to a generic publish() if your EventBus has it.
		if EventBus.has_signal(signal_name):
			match args.size():
				0:
					EventBus.emit_signal(signal_name)
				1:
					EventBus.emit_signal(signal_name, args[0])
				2:
					EventBus.emit_signal(signal_name, args[0], args[1])
				3:
					EventBus.emit_signal(signal_name, args[0], args[1], args[2])
				_:
					# For >3 args, you can extend as needed or switch to a dictionary payload.
					EventBus.emit_signal(signal_name, args)
		elif _has_method(EventBus, "publish"):
			# Generic bus API: publish(name: String, payload: Variant)
			var payload: Dictionary = { "args": args }
			EventBus.publish(signal_name, payload)

func _has_method(obj: Variant, method_name: String) -> bool:
	return is_instance_valid(obj) and obj is Object and obj.has_method(method_name)

func _has_autoload(name: String) -> bool:
	# Checks presence of an autoload at /root/<name> (reliable both in editor & runtime).
	return has_node("/root/" + name)
