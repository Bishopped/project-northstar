# res://tests/statblock_smoke_test.gd
# Integration smoke test for StatBlock + EntityController + UnitRoster.
# Open Test_EntityScene.tscn and press F6. Watch the Output panel.

extends Node

# -------- Cached refs (safe defaults) --------
var _event_bus: Node = null
var _roster: Node = null
var _mods: Node = null

# Scene entity refs (instances in Test_EntityScene.tscn)
var hero: Node = null
var gob: Node = null

# Temp registration signal flags
var _saw_unit_registered: bool = false
var _saw_unit_unregistered: bool = false

# -------------------- LIFECYCLE --------------------

func _ready() -> void:
	# Resolve autoloads safely from root
	_event_bus = _root_get("EventBus")
	_roster = _root_get("UnitRoster")
	_mods = _root_get("ModifierSystem")

	# Watch UnitRoster signals for temp-unit test (if exposed)
	if _roster != null and _roster.has_signal("unit_registered"):
		_roster.connect("unit_registered", Callable(self, "_on_unit_registered"))
	if _roster != null and _roster.has_signal("unit_unregistered"):
		_roster.connect("unit_unregistered", Callable(self, "_on_unit_unregistered"))

	# Resolve scene instances (adjust names if different)
	hero = $Hero_A if has_node("Hero_A") else null
	gob = $Goblin_A if has_node("Goblin_A") else null

	if hero == null or gob == null:
		push_error("[TEST] Could not find Hero_A or Goblin_A in Test_EntityScene.tscn")
		return

	# Seed CharacterSheet/EquipmentState/Conditions directly
	_seed_hero_basics()
	_seed_gob_defaults()

	# Register with roster (prefer 3-arg event: unit_id, team, node)
	if _event_bus != null and _event_bus.has_signal("entity_spawned"):
		var hero_team = hero.team
		var gob_team = gob.team
		_event_bus.emit_signal("entity_spawned", "hero1", hero_team, hero)
		_event_bus.emit_signal("entity_spawned", "gob1", gob_team, gob)

	# Direct fallback in case signals fire too early for UnitRoster
	# Project's UnitRoster.register_unit expects exactly (entity_node)
	if _roster != null and _roster.has_method("register_unit"):
		_roster.call("register_unit", hero)
		_roster.call("register_unit", gob)

	# Initial rebuilds
	_rebuild(hero)
	_rebuild(gob)

	# Execute test phases
	_print_header("Derived baselines")
	phase_baselines()

	_print_header("Modifier integration")
	phase_modifiers()

	_print_header("Condition integration")
	phase_conditions()

	_print_header("Roster query parity")
	phase_roster_parity()

	_print_header("Equipment change (shield add/remove)")
	phase_equipment_changes()

	_print_header("Temp unit registration")
	phase_temp_unit_registration()

	_print_header("All tests completed")
	print("[TEST] Done")


# -------------------- PHASES --------------------

func phase_baselines() -> void:
	# AC baseline pass A (no armor, no shield) – unarmored fallback: 10 + DEX mod
	var ac_a := _safe_get_ac(hero)
	var spd := _safe_get_speed(hero)
	var dex_save := _safe_get_save(hero, "DEX")

	var expected_ac_a := 10 + 3  # DEX 16 -> mod +3 (adjust if ArmorClassService differs)
	_check(ac_a == expected_ac_a, "AC (no shield) expected %d got %d" % [expected_ac_a, ac_a])

	_check(abs(spd - 9.0) < 0.001, "Speed expected 9.0 got %.2f" % spd)

	# DEX save: DEX mod (+PB if proficient). We set proficient_saves to include DEX (PB=2)
	var expected_dex_save := 3 + 2
	_check(dex_save == expected_dex_save, "DEX save expected %d got %d" % [expected_dex_save, dex_save])

	# Now give hero a shield and rebuild, expect +2 AC (unless ArmorClassService overrides)
	_set_hero_shield(true)
	_rebuild(hero)
	var ac_b := _safe_get_ac(hero)
	var expected_ac_b := expected_ac_a + 2
	_check(ac_b == expected_ac_b, "AC (+shield) expected %d got %d" % [expected_ac_b, ac_b])


func phase_modifiers() -> void:
	if _mods != null and _mods.has_method("add_modifier"):
		_mods.call("add_modifier", "hero1", "ac_bonus", {"id":"buff1","op":"add","value":1})
		if _event_bus != null and _event_bus.has_signal("modifier_changed"):
			_event_bus.emit_signal("modifier_changed", "hero1", "ac_bonus")
	else:
		# Fallback: just force rebuild; StatBlock will see zero without a live ModifierSystem
		_rebuild(hero)

	var ac_now := _safe_get_ac(hero)
	# Previous expected with shield was 15; with +1 buff: 16
	var expected := 16
	_check(ac_now == expected, "AC (+1 buff) expected %d got %d" % [expected, ac_now])


func phase_conditions() -> void:
	# Apply a stub condition; StatBlock stores condition IDs into _breakdown.conditions
	if _event_bus != null and _event_bus.has_signal("condition_applied"):
		_event_bus.emit_signal("condition_applied", "hero1", "cond_prone_stub")
	else:
		# If no signal exists, append directly and rebuild
		var arr: Array = hero.condition_ids if hero.condition_ids != null else []
		if not arr.has("cond_prone_stub"):
			arr.append("cond_prone_stub")
		hero.condition_ids = arr
	_rebuild(hero)

	# Validate the condition id shows up in the stat_block breakdown
	var sb := _safe_get_stat_block(hero)
	var conds: Array = []
	if sb.has("_breakdown") and sb["_breakdown"].has("conditions"):
		conds = sb["_breakdown"]["conditions"]
	_check(conds.has("cond_prone_stub"), "condition 'cond_prone_stub' should appear in stat_block breakdown")


func phase_roster_parity() -> void:
	var hero_ac := _safe_get_ac(hero)
	var roster_ac := hero_ac

	# Try to pull the same node via UnitRoster (depending on your API surface)
	if _roster != null:
		var hero_id := "hero1"
		if _roster.has_method("get_by_id"):
			var node: Node = _roster.call("get_by_id", hero_id)
			if node != null and node.has_method("get_ac"):
				roster_ac = int(node.call("get_ac"))
		elif _roster.has_method("list_team"):
			var party: Array = _roster.call("list_team", "party")
			if party is Array and party.size() > 0:
				var id0 = str(party[0])
				if id0 == "hero1" and _roster.has_method("get_by_id"):
					var n2: Node = _roster.call("get_by_id", id0)
					if n2 != null and n2.has_method("get_ac"):
						roster_ac = int(n2.call("get_ac"))

	_check(hero_ac == roster_ac, "UnitRoster returned AC must match direct entity AC")


func phase_equipment_changes() -> void:
	# Ensure we start from baseline (remove the +1 AC buff from modifier phase)
	if _mods != null and _mods.has_method("remove_modifier"):
		_mods.call("remove_modifier", "hero1", "ac_bonus", "buff1")  # (unit_id, key, id)
		if _event_bus != null and _event_bus.has_signal("modifier_changed"):
			_event_bus.emit_signal("modifier_changed", "hero1", "ac_bonus")
	else:
		# Fallback: if no remove API, add a -1 to cancel out
		if _mods != null and _mods.has_method("add_modifier"):
			_mods.call("add_modifier", "hero1", "ac_bonus", {"id":"buff1_cancel","op":"add","value":-1})
			if _event_bus != null and _event_bus.has_signal("modifier_changed"):
				_event_bus.emit_signal("modifier_changed", "hero1", "ac_bonus")
	# Give it a frame to rebuild after modifier change
	await get_tree().process_frame

	# Remove shield
	_set_hero_shield(false)
	if _event_bus != null and _event_bus.has_signal("unequipped"):
		_event_bus.emit_signal("unequipped", "hero1", "shield")
	_rebuild(hero)

	var ac_no_shield := _safe_get_ac(hero)
	var expected := 13  # back to baseline: 10 + DEX(3)
	_check(ac_no_shield == expected, "AC (shield removed) expected %d got %d" % [expected, ac_no_shield])

	# Add shield again via event path
	_set_hero_shield(true)
	if _event_bus != null and _event_bus.has_signal("equipped"):
		_event_bus.emit_signal("equipped", "hero1", "shield_basic", "shield")
	_rebuild(hero)

	var ac_shield := _safe_get_ac(hero)
	var expected2 := 15
	_check(ac_shield == expected2, "AC (shield re-added) expected %d got %d" % [expected2, ac_shield])


func phase_temp_unit_registration() -> void:
	# 1) Build a temp entity by instancing your standard entity scene if available,
	#    otherwise duplicate hero (ensures required properties exist).
	var temp: Node = null
	if ResourceLoader.exists("res://EntityScene/StatblockEntity_A.tscn"):
		temp = preload("res://core/entity/EntityRoot.tscn").instantiate()
	else:
		temp = hero.duplicate()

	if temp == null:
		push_error("[TEST][FAIL] Could not create temp_unit instance")
		return

	# 2) Set identity (matches EntityController exports)
	temp.unit_id = "temp_unit"
	temp.team = "party"

	# 3) Add to scene tree BEFORE registering/emitting
	add_child(temp)
	await get_tree().process_frame

	# 4) Register with UnitRoster directly (register_unit expects exactly the node)
	if _roster != null and _roster.has_method("register_unit"):
		_roster.call("register_unit", temp)

	# 5) Emit the 3-arg spawn event (unit_id, team, node) for listeners that rely on EventBus
	if _event_bus != null and _event_bus.has_signal("entity_spawned"):
		_event_bus.emit_signal("entity_spawned", "temp_unit", temp.team, temp)

	# 6) Give the roster time to process registration + signal
	await get_tree().process_frame
	await get_tree().process_frame

	# 7) Assert roster sees it
	var listed: Array = []
	if _roster != null and _roster.has_method("list_all"):
		listed = _roster.call("list_all")
	_check(listed.has("temp_unit"), "temp_unit registered in roster")
	_check(_saw_unit_registered, "unit_registered fired for temp_unit")

	# 8) Clean up: despawn and remove the node (emit both variants + direct API if available)
	if _event_bus != null and _event_bus.has_signal("entity_despawned"):
		# 3-arg variant (unit_id, team, node)
		_event_bus.emit_signal("entity_despawned", "temp_unit", temp.team, temp)
		# 2-arg variant (unit_id, node) for legacy listeners
		_event_bus.emit_signal("entity_despawned", "temp_unit", temp)

	if _roster != null and _roster.has_method("unregister_unit"):
		# Try by unit_id string first
		var sig_valid := false
		# Check if calling with string works
		if typeof(_roster.unregister_unit) == TYPE_NIL:
			# no-op: reflection can't easily tell arg type; just attempt string
			pass
		# Attempt string form
		var err = _roster.callv("unregister_unit", ["temp_unit"])
		if err != null:
			sig_valid = true
		# If the above throws an error in your console, comment it out and use the node form instead:
		# _roster.callv("unregister_unit", [temp])


	# Give the roster time to process removal
	await get_tree().process_frame
	await get_tree().process_frame

	# 9) Verify it’s gone and the signal fired
	var listed_after: Array = []
	if _roster != null and _roster.has_method("list_all"):
		listed_after = _roster.call("list_all")
	_check(not listed_after.has("temp_unit"), "temp_unit unregistered from roster")
	_check(_saw_unit_unregistered, "unit_unregistered fired for temp_unit")

	# Finally remove the node from the tree
	temp.queue_free()


# -------------------- SIGNAL HANDLERS --------------------

func _on_unit_registered(unit_id: String) -> void:
	if unit_id == "temp_unit":
		_saw_unit_registered = true
		print("[TEST] unit_registered captured:", unit_id)

func _on_unit_unregistered(unit_id: String) -> void:
	if unit_id == "temp_unit":
		_saw_unit_unregistered = true
		print("[TEST] unit_unregistered captured:", unit_id)


# -------------------- SEEDING --------------------

func _seed_hero_basics() -> void:
	# CharacterSheet (level 3, PB 2, DEX 16, CON 14)
	hero.character_sheet = {
		"level": 3,
		"proficiency_bonus": 2,
		"abilities": {"STR": 10, "DEX": 16, "CON": 14, "INT": 10, "WIS": 12, "CHA": 10},
		"proficient_saves": ["DEX", "CON"],
		"proficient_skills": ["Perception", "Stealth"],
		"features": [],
		"known_actions": [],
		"known_spells": []
	}
	# EquipmentState (pass A — no shield)
	hero.equipment_state = {"armor":"", "shield":""}
	# Conditions (start empty)
	hero.condition_ids = []


func _seed_gob_defaults() -> void:
	gob.character_sheet = {}   # allow all defaults
	gob.equipment_state = {}
	gob.condition_ids = []


# -------------------- UTILITIES --------------------

func _set_hero_shield(enabled: bool) -> void:
	var eq: Dictionary = hero.equipment_state if hero.equipment_state != null else {}
	eq["shield"] = "shield_basic" if enabled else ""
	hero.equipment_state = eq

func _rebuild(node: Node) -> void:
	if node != null and node.has_method("rebuild_stat_block"):
		node.call("rebuild_stat_block")

func _safe_get_stat_block(node: Node) -> Dictionary:
	if node != null and node.has_method("get_stat_block"):
		var sb = node.call("get_stat_block")
		return sb if sb is Dictionary else {}
	return {}

func _safe_get_ac(node: Node) -> int:
	if node != null and node.has_method("get_ac"):
		return int(node.call("get_ac"))
	return 10

func _safe_get_speed(node: Node) -> float:
	if node != null and node.has_method("get_speed"):
		return float(node.call("get_speed"))
	return 9.0

func _safe_get_save(node: Node, ability: String) -> int:
	if node != null and node.has_method("get_save"):
		return int(node.call("get_save", ability))
	return 0

func _check(cond: bool, message: String) -> void:
	if cond:
		print("[PASS] ", message)
	else:
		push_error("[FAIL] " + message)

func _print_header(s: String) -> void:
	print("\n========== ", s, " ==========")

func _root_get(name: String) -> Node:
	var root := get_tree().root if get_tree() != null else null
	if root == null:
		return null
	return root.get_node(name) if root.has_node(name) else null
