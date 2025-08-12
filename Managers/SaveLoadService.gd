extends Node
class_name SaveLoadServiceCore
## Autoload name registered as "SaveLoadService" (different from class_name per project rule).

## ─────────────────────────────────────────────────────────────────────────────
## SaveLoadService – Versioned, deterministic save/load with migration & slots
## ─────────────────────────────────────────────────────────────────────────────

## Public signals (consumed by UI or other systems)
signal save_completed(slot_id : String)
signal load_completed(slot_id : String)
signal save_failed(slot_id : String, reason : String)
signal load_failed(slot_id : String, reason : String)

## Schema/versioning
const SCHEMA_VERSION : int = 1

## Save folder layout
const ROOT_SAVE_DIR : String = "user://saves"

## Autosave config (tweakable; kept simple for Phase 1)
@export var autosave_enabled			: bool = true
@export var autosave_turn_interval		: int = 1		## every N turns (min 1)
@export var autosave_label_prefix		: String = "Autosave"
var _turn_counter_since_last_autosave	: int = 0

## Deterministic RNG – use a dedicated RNG instance
var _rng : RandomNumberGenerator = RandomNumberGenerator.new()
var _rng_seed : int = 0

## Cached references (resolved at runtime, null-safe)
var _event_bus			: Node = null			## [[Managers/EventBus]]
var _data_registry		: Node = null			## [[Managers/DataRegistry]]
var _condition_manager	: Node = null			## [[Managers/ConditionManager]]
var _unit_roster		: Node = null			## [[Managers/UnitRoster]]
var _combat_system		: Node = null			## [[Systems/CombatSystem]]

func _ready() -> void:
	## Initialize RNG with a stable default seed; projects can override via set_rng_seed()
	_rng_seed = 0
	_rng.seed = _rng_seed

	## Resolve known singletons by their autoload names when available.
	_data_registry = get_node_or_null("/root/DataRegistry")
	_event_bus = get_node_or_null("/root/EventBus")
	_condition_manager = get_node_or_null("/root/ConditionManager")
	_unit_roster = get_node_or_null("/root/UnitRoster")
	_combat_system = get_node_or_null("/root/CombatSystem")

	## Subscribe to EventBus if it exposes either:
	## 	A) specific signals (encounter_started/ended, turn_ended, levelup_complete), or
	## 	B) a generic dispatcher like "event_emitted(event_name, payload)"
	if _event_bus:
		## Try specific signal names first (preferred)
		_try_connect(_event_bus, "encounter_started", "_on_encounter_started")
		_try_connect(_event_bus, "encounter_ended", "_on_encounter_ended")
		_try_connect(_event_bus, "turn_ended", "_on_turn_ended")
		_try_connect(_event_bus, "levelup_complete", "_on_levelup_complete")
		## Fallback: generic bus pattern
		_try_connect(_event_bus, "event_emitted", "_on_event_emitted")

	## Ensure save root exists
	_ensure_dir(ROOT_SAVE_DIR)

## ─────────────────────────────────────────────────────────────────────────────
## Public API
## ─────────────────────────────────────────────────────────────────────────────

func set_rng_seed(seed : int) -> void:
	## Must be called before new rolls to keep determinism.
	_rng_seed = seed
	_rng.seed = _rng_seed

func get_rng_seed() -> int:
	return _rng_seed

func save_to_slot(slot_id : String, label : String = "") -> bool:
	if slot_id.is_empty():
		_emit_save_failed(slot_id, "slot_id_empty")
		return false
	var slot_dir := "%s/%s" % [ROOT_SAVE_DIR, slot_id]
	_ensure_dir(slot_dir)

	var snapshot := _assemble_snapshot()
	if snapshot.is_empty():
		_emit_save_failed(slot_id, "empty_snapshot")
		return false

	## Main save.json
	var save_path := "%s/save.json" % slot_dir
	var ok := _write_json(save_path, snapshot)
	if not ok:
		_emit_save_failed(slot_id, "write_save_failed")
		return false

	## meta.json (timestamp, version, label)
	var meta := {
		"version": SCHEMA_VERSION,
		"label": label if not label.is_empty() else ("%s %s" % [autosave_label_prefix, Time.get_datetime_string_from_system()]),
		"timestamp": Time.get_unix_time_from_system()
	}
	var meta_ok := _write_json("%s/meta.json" % slot_dir, meta)
	if not meta_ok:
		_emit_save_failed(slot_id, "write_meta_failed")
		return false

	emit_signal("save_completed", slot_id)
	return true

func load_from_slot(slot_id : String) -> bool:
	if slot_id.is_empty():
		_emit_load_failed(slot_id, "slot_id_empty")
		return false

	var slot_dir := "%s/%s" % [ROOT_SAVE_DIR, slot_id]
	var save_path := "%s/save.json" % slot_dir
	if not FileAccess.file_exists(save_path):
		_emit_load_failed(slot_id, "missing_save_json")
		return false

	var parsed = _read_json(save_path)
	if parsed == null:
		_emit_load_failed(slot_id, "parse_failed")
		return false

	## Migration step-by-step if needed
	var migrated : Dictionary = migrate_save(parsed) if int(parsed.get("version", 0)) < SCHEMA_VERSION else parsed
	if migrated == {}:
		_emit_load_failed(slot_id, "migration_failed")
		return false

	## Apply in strict order for null-safety/determinism
	var ok = _apply_snapshot(migrated)
	if not ok:
		_emit_load_failed(slot_id, "apply_failed")
		return false

	emit_signal("load_completed", slot_id)
	return true

func list_slots() -> Array:
	var out : Array = []
	var dir := DirAccess.open(ROOT_SAVE_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name != "." and name != "..":
			var slot_dir := "%s/%s" % [ROOT_SAVE_DIR, name]
			var meta_path := "%s/meta.json" % slot_dir
			var meta : Dictionary = _read_json(meta_path) if FileAccess.file_exists(meta_path) else {}
			out.append({
				"slot_id": name,
				"label": str(meta.get("label", "")),
				"version": int(meta.get("version", 0)),
				"timestamp": int(meta.get("timestamp", 0))
			})
		name = dir.get_next()
	dir.list_dir_end()
	## Optional: sort newest first
	out.sort_custom(func(a, b): return int(b.get("timestamp", 0)) < int(a.get("timestamp", 0)))
	return out

func delete_slot(slot_id : String) -> bool:
	if slot_id.is_empty():
		return false
	var slot_dir := "%s/%s" % [ROOT_SAVE_DIR, slot_id]
	return _delete_dir_recursive(slot_dir)

## Debug helpers (for test scene buttons or debug console)
func debug_quick_save() -> void:
	save_to_slot("quick", "Quick Save")

func debug_quick_load() -> void:
	load_from_slot("quick")

## ─────────────────────────────────────────────────────────────────────────────
## Migration
## ─────────────────────────────────────────────────────────────────────────────

func migrate_save(data : Dictionary) -> Dictionary:
	## Upgrade "data" in steps until it reaches SCHEMA_VERSION.
	## Log at each step for visibility during tests.
	var working := data.duplicate(true)
	var version := int(working.get("version", 0))

	if version <= 0:
		## Pre-1 bootstrap → set version 1 defaults
		version = 1
		working["version"] = 1
		working["rng_seed"] = int(working.get("rng_seed", 0))
		if not working.has("character_sheets"):
			working["character_sheets"] = []
		if not working.has("combatant_states"):
			working["combatant_states"] = []
		if not working.has("world_state"):
			working["world_state"] = {}
		if not working.has("encounter"):
			working["encounter"] = null
		print("[SaveLoadService] Migrated pre-v1 → v1")

	## Future: if version == 1 and SCHEMA_VERSION == 2, do v1→v2 changes here, etc.

	working["version"] = SCHEMA_VERSION
	return working

## ─────────────────────────────────────────────────────────────────────────────
## Assemble (pull from systems) / Apply (push to systems)
## ─────────────────────────────────────────────────────────────────────────────

func _assemble_snapshot() -> Dictionary:
	## Pulls from runtime systems. For Phase 1, we keep it minimal but structurally sound.
	## Safe defaults ensure we never produce invalid JSON.
	var snapshot : Dictionary = {
		"version": SCHEMA_VERSION,
		"rng_seed": _rng_seed,
		"character_sheets": _gather_character_sheets(),		## [[Runtime/CharacterSheet]]
		"combatant_states": _gather_combatant_states(),		## [[Runtime/CombatantState]]
		"world_state": _gather_world_state(),					## [[Runtime/WorldState]] / [[Runtime/ExplorationState]]
		"encounter": _gather_encounter_context()				## [[Managers/UnitRoster]] / [[Systems/CombatSystem]]
	}
	return snapshot

func _apply_snapshot(snapshot : Dictionary) -> bool:
	## 1) RNG seed
	var seed := int(snapshot.get("rng_seed", 0))
	set_rng_seed(seed)

	## 2) DataRegistry readiness (verify only for Phase 1; no await here to avoid coroutine)
	if not _is_data_registry_ready():
		## Phase 1: proceed but warn; Phase 2+: await a proper ready signal from DataRegistry.
		print("[SaveLoadService] DataRegistry not ready; proceeding with caution (Phase 1).")

	## 3) CharacterSheet → Equipment/Inventory
	_restore_character_sheets(snapshot.get("character_sheets", []))

	## 4) Rebuild StatBlocks
	_rebuild_stat_blocks()

	## 5) Conditions (ConditionManager)
	_reapply_conditions(snapshot.get("combatant_states", []))

	## 6) CombatantState (HP/resources/concentration)
	_restore_combatant_states(snapshot.get("combatant_states", []))

	## 7) UnitRoster & CombatSystem initiative (if encounter present)
	_restore_encounter_context(snapshot.get("encounter", null))

	## 8) WorldState / ExplorationState
	_restore_world_state(snapshot.get("world_state", {}))

	return true

## ─────────────────────────────────────────────────────────────────────────────
## Gather helpers (Phase 1 stubs with safe structures)
## ─────────────────────────────────────────────────────────────────────────────

func _gather_character_sheets() -> Array:
	## TODO: Pull from your party/character controllers.
	## For Phase 1 we return an empty list structure.
	## Expected record shape (example):
	## {
	## 	"id": "pc_1",
	## 	"name": "Weaver",
	## 	"abilities": {"str":10,"dex":16,"con":12,"int":14,"wis":10,"cha":8},
	## 	"class_levels": [{"class_id":"rogue","level":5}],
	## 	"features": ["cunning_action","evasion"],
	## 	"known_actions": ["attack","dash"],
	## 	"known_spells": ["shield","misty_step"],
	## 	"inventory": [{"item_id":"potion_healing","qty":2}],
	## 	"equipped": {"weapon_main":"shortsword+1","armor":"leather"},
	## }
	return []

func _gather_combatant_states() -> Array:
	## TODO: Read active units’ HP/temp HP/resources/conditions/concentration/death saves.
	## Example shape:
	## {
	## 	"unit_id":"pc_1",
	## 	"hp": 27,
	## 	"temp_hp": 5,
	## 	"conditions": [{"id":"poisoned","remaining_rounds":3}],
	## 	"resources": {"slots":{"1":4,"2":2}},
	## 	"concentration": {"target_unit_id":"enemy_1","action_id":"hold_person"},
	## 	"death_saves": {"success":1,"fail":0}
	## }
	return []

func _gather_world_state() -> Dictionary:
	## TODO: Pull from your world/exploration singleton(s).
	## Example: {"time":{"day":12,"hour":15},"weather":"rain","region_flags":["underdark"]...}
	return {}

func _gather_encounter_context() -> Variant:
	## If not in combat, return null. Otherwise include initiative + index, whose turn,
	## alive unit ids/factions, and active EncounterTemplateResource id.
	## Example:
	## {
	## 	"in_initiative": true,
	## 	"order": ["pc_1","enemy_1"],
	## 	"indices": {"pc_1":0,"enemy_1":1},
	## 	"current_index": 0,
	## 	"active_unit_id": "pc_1",
	## 	"factions_alive": {"players":["pc_1"],"enemies":["enemy_1"]},
	## 	"encounter_template_id": "enc_goblin_ambush"
	## }
	return null

## ─────────────────────────────────────────────────────────────────────────────
## Restore helpers (Phase 1 stubs – null-safe)
## ─────────────────────────────────────────────────────────────────────────────

func _restore_character_sheets(list : Array) -> void:
	## TODO: Push records into your party/character controllers; create/rebind instances.
	## Must run before rebuilding StatBlocks.
	for _rec in list:
		pass

func _rebuild_stat_blocks() -> void:
	## TODO: Trigger stat recomputation per [[Runtime/StatBlock]] rules.
	pass

func _reapply_conditions(combatant_list : Array) -> void:
	## After StatBlocks exist, re-apply condition IDs and remaining durations via [[Managers/ConditionManager]].
	if _condition_manager == null:
		return
	for rec in combatant_list:
		var conds : Array = rec.get("conditions", [])
		for c in conds:
			var id := str(c.get("id", ""))
			var remain := int(c.get("remaining_rounds", 0))
			if id.is_empty():
				continue
			## Replace with your ConditionManager API
			if _condition_manager.has_method("apply_condition_id_with_duration"):
				_condition_manager.apply_condition_id_with_duration(rec.get("unit_id", ""), id, remain)

func _restore_combatant_states(list : Array) -> void:
	for rec in list:
		var unit_id := str(rec.get("unit_id", ""))
		if unit_id.is_empty():
			continue
		## HP/Temp HP/resources/concentration/death saves:
		## Replace with your combatant controller API as it comes online.
		## Keep null-safe for Phase 1.
		pass

func _restore_encounter_context(ctx : Variant) -> void:
	if ctx == null:
		return
	## Rebuild initiative, whose turn, unit roster and factions; defer to CombatSystem/UnitRoster APIs when present.
	if _unit_roster and _unit_roster.has_method("restore_from_ids"):
		_unit_roster.restore_from_ids(ctx)
	if _combat_system and _combat_system.has_method("restore_initiative_context"):
		_combat_system.restore_initiative_context(ctx)

func _restore_world_state(ws : Dictionary) -> void:
	## Push time/weather/region flags/formation/discovered POIs into your world/exploration singleton(s).
	pass

## ─────────────────────────────────────────────────────────────────────────────
## EventBus autosave hooks
## ─────────────────────────────────────────────────────────────────────────────

func _on_encounter_started(_payload = null) -> void:
	if not autosave_enabled:
		return
	save_to_slot("autosave_encounter_start", "%s: Encounter Start" % autosave_label_prefix)

func _on_encounter_ended(_payload = null) -> void:
	if not autosave_enabled:
		return
	save_to_slot("autosave_encounter_end", "%s: Encounter End" % autosave_label_prefix)

func _on_turn_ended(_payload = null) -> void:
	if not autosave_enabled:
		return
	_turn_counter_since_last_autosave += 1
	if _turn_counter_since_last_autosave >= max(1, autosave_turn_interval):
		_turn_counter_since_last_autosave = 0
		save_to_slot("autosave_turn", "%s: Turn" % autosave_label_prefix)

func _on_levelup_complete(_payload = null) -> void:
	if not autosave_enabled:
		return
	save_to_slot("autosave_levelup", "%s: Level Up" % autosave_label_prefix)

## Fallback generic EventBus pattern (event_name, payload)
func _on_event_emitted(event_name : String, payload : Variant) -> void:
	match event_name:
		"encounter_started":
			_on_encounter_started(payload)
		"encounter_ended":
			_on_encounter_ended(payload)
		"turn_ended":
			_on_turn_ended(payload)
		"levelup_complete":
			_on_levelup_complete(payload)
		_:
			pass

## ─────────────────────────────────────────────────────────────────────────────
## Utility / I/O
## ─────────────────────────────────────────────────────────────────────────────

func _is_data_registry_ready() -> bool:
	# Prefer an explicit API on DataRegistry
	if _data_registry == null:
		return false

	# If your DataRegistry has is_ready(), use it.
	if _data_registry.has_method("is_ready"):
		var r = _data_registry.is_ready()
		return r is bool and r or false  # ensure bool

	# Fallback: assume ready (Phase 1) if no method exists.
	# Remove this fallback once DataRegistry exposes is_ready().
	return true

func _ensure_dir(path : String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		DirAccess.make_dir_recursive_absolute(path)

func _write_json(path : String, data : Variant) -> bool:
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return false
	var json := JSON.stringify(data, "\t", false)	## pretty print with tabs
	fa.store_string(json)
	fa.flush()
	fa.close()
	return true

func _read_json(path : String) -> Variant:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return null
	var txt := fa.get_as_text()
	fa.close()
	var parser := JSON.new()
	var err := parser.parse(txt)
	if err != OK:
		return null
	return parser.data

func _delete_dir_recursive(path : String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := "%s/%s" % [path, name]
		if dir.current_is_dir():
			if name != "." and name != "..":
				_delete_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		name = dir.get_next()
	dir.list_dir_end()
	return DirAccess.remove_absolute(path) == OK

func _try_connect(target : Object, sig : String, method_name : String) -> void:
	if not target:
		return
	if target.has_signal(sig):
		var callable := Callable(self, method_name)
		if not target.is_connected(sig, callable):
			target.connect(sig, callable)

func _emit_save_failed(slot_id : String, reason : String) -> void:
	print("[SaveLoadService] save_failed: %s (%s)" % [slot_id, reason])
	emit_signal("save_failed", slot_id, reason)

func _emit_load_failed(slot_id : String, reason : String) -> void:
	print("[SaveLoadService] load_failed: %s (%s)" % [slot_id, reason])
	emit_signal("load_failed", slot_id, reason)
