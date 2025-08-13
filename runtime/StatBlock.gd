# res://Runtime/StatBlock.gd
# Plain script module that builds a deterministic derived stat dictionary
# from CharacterSheet, EquipmentState, Conditions, and ModifierSystem.
# Links to vault notes:
# - [[Runtime/CharacterSheet]], [[Runtime/EquipmentState]], [[Managers/ConditionManager]]
# - [[Systems/ModifierSystem]], [[Systems/ArmorClassService]]

class_name StatBlock  # Not an autoload; safe to use class_name.

# --------- Public API ---------
# build(unit_id, character_sheet, equipment_state, condition_ids) -> Dictionary
# query(total, key, default_value) -> Variant
# explain(unit_id, key) -> Dictionary   (optional; stubbed)
# get_ac(unit_id, total) -> int
# get_speed(unit_id, total) -> float
# get_save(total, ability) -> int

static func build(unit_id: String, character_sheet: Dictionary, equipment_state: Dictionary, condition_ids: Array) -> Dictionary:
	# Safe input defaults
	var cs: Dictionary = character_sheet if character_sheet != null else {}
	var eq: Dictionary = equipment_state if equipment_state != null else {}
	var conds: Array = condition_ids if condition_ids != null else []

	# Resolve services best‑effort (may be null) — we're in a static fn, so use the SceneTree root
	var root: Node = Engine.get_main_loop().root
	var modifier_system: Node = null
	var armor_service: Node = null
	if root != null:
		modifier_system = root.get_node("ModifierSystem") if root.has_node("ModifierSystem") else null
		armor_service = root.get_node("ArmorClassService") if root.has_node("ArmorClassService") else null

	# --------- Base scaffold with safe defaults ---------
	var out: Dictionary = {
		"unit_id": unit_id,
		# Core
		"proficiency_bonus": 2,           # default PB for low levels
		"abilities": {                    # ability modifiers
			"STR": 0, "DEX": 0, "CON": 0, "INT": 0, "WIS": 0, "CHA": 0
		},
		"ac": 10,                         # default unarmored AC
		"speed": 9.0,                     # meters (≈30 ft)
		"initiative_mod": 0,
		# Defenses
		"save_mods": {
			"STR": 0, "DEX": 0, "CON": 0, "INT": 0, "WIS": 0, "CHA": 0
		},
		# Damage traits
		"resistances": [],                # arrays of strings e.g., ["fire","cold"]
		"immunities": [],
		"vulnerabilities": [],
		# Senses (stubs)
		"darkvision": 0,
		"blindsight": 0,
		"passive_perception": 10,
		# Checks (subset)
		"check_mods": {
			"Stealth": 0,
			"Perception": 0
		},
		# Flags
		"has_shield": false,
		"armor_type": "none",             # "none","light","medium","heavy"
		"concentration_advantage": false,
		# Breakdown (optional — for explain())
		"_breakdown": {}
	}

	# --------- Read character sheet basics ---------
	var scores: Dictionary = cs.get("abilities", {})
	var level: int = int(cs.get("level", 1))
	var pb: int = int(cs.get("proficiency_bonus", _derive_pb(level)))
	out["proficiency_bonus"] = pb

	# Ability mods
	var abil_names := ["STR","DEX","CON","INT","WIS","CHA"]
	for a in abil_names:
		var score: int = int(scores.get(a, 10))
		out["abilities"][a] = _mod(score)

	# Initiative (DEX mod baseline; adv handled via modifiers/flags later)
	out["initiative_mod"] = out["abilities"]["DEX"]

	# --------- Equipment & base AC/speed flags ---------
	# Expect equipment_state like: { "armor": "<item_id or ''>", "shield": "<item_id or ''>", "slots": {...} }
	var armor_item_id: String = str(eq.get("armor", ""))
	var shield_item_id: String = str(eq.get("shield", ""))
	out["has_shield"] = shield_item_id != ""
	out["armor_type"] = _infer_armor_type(armor_item_id)  # stub inference by id pattern or lookup later

	# --------- Conditions present (IDs only — effects come via ModifierSystem) ---------
	out["_breakdown"]["conditions"] = conds.duplicate()

	# --------- Baselines before modifiers ---------
	var base_ac: int = _base_ac_from_armor(out["armor_type"], out["abilities"]["DEX"], out["has_shield"])
	var base_speed: float = 9.0

	# --------- Apply services: ArmorClassService or local AC calc ---------
	if armor_service != null and armor_service.has_method("compute_ac_for_unit"):
		out["ac"] = int(armor_service.call("compute_ac_for_unit", unit_id, armor_item_id, shield_item_id, out["abilities"]))
	else:
		out["ac"] = base_ac

	out["speed"] = base_speed

	# --------- Saves & checks baseline ---------
	for a in abil_names:
		var prof_saves: Array = cs.get("proficient_saves", [])
		var base_save: int = out["abilities"][a] + (pb if prof_saves.has(a) else 0)
		out["save_mods"][a] = base_save

	# Checks subset
	var prof_skills: Array = cs.get("proficient_skills", [])
	out["check_mods"]["Perception"] = out["abilities"]["WIS"] + (pb if prof_skills.has("Perception") else 0)
	out["check_mods"]["Stealth"] = out["abilities"]["DEX"] + (pb if prof_skills.has("Stealth") else 0)
	out["passive_perception"] = 10 + out["check_mods"]["Perception"]

	# --------- Pull final modifiers from ModifierSystem ---------
	if modifier_system != null:
		_apply_modifiers(unit_id, out, modifier_system)

	# Return a deep copy as an immutable-ish payload for consumers
	return _deep_copy(out)


static func query(total: Dictionary, key: String, default_value: Variant) -> Variant:
	return total.get(key, default_value)


static func explain(unit_id: String, key: String) -> Dictionary:
	# Optional: provide a breakdown – stubbed for now
	return {"unit_id": unit_id, "key": key, "notes": "Breakdown not implemented yet."}


static func get_ac(unit_id: String, total: Dictionary) -> int:
	return int(total.get("ac", 10))


static func get_speed(unit_id: String, total: Dictionary) -> float:
	return float(total.get("speed", 9.0))


static func get_save(total: Dictionary, ability: String) -> int:
	var saves: Dictionary = total.get("save_mods", {})
	return int(saves.get(ability, 0))


# --------- Internal helpers ---------

static func _derive_pb(level: int) -> int:
	if level >= 17:
		return 6
	elif level >= 13:
		return 5
	elif level >= 9:
		return 4
	elif level >= 5:
		return 3
	return 2


static func _mod(score: int) -> int:
	return int(floor((score - 10) / 2.0))


static func _infer_armor_type(armor_item_id: String) -> String:
	if armor_item_id == "":
		return "none"
	if armor_item_id.begins_with("armor_heavy_"):
		return "heavy"
	if armor_item_id.begins_with("armor_medium_"):
		return "medium"
	if armor_item_id.begins_with("armor_light_"):
		return "light"
	return "none"


static func _base_ac_from_armor(armor_type: String, dex_mod: int, has_shield: bool) -> int:
	var ac: int = 10
	if armor_type == "light":
		ac = 11 + dex_mod
	elif armor_type == "medium":
		ac = 12 + min(dex_mod, 2)
	elif armor_type == "heavy":
		ac = 16  # sample baseline; real values should read from Data/ItemResource
	else:
		ac = 10 + dex_mod  # simple unarmored fallback
	if has_shield:
		ac += 2
	return ac


static func _apply_modifiers(unit_id: String, out: Dictionary, modifier_system: Node) -> void:
	# Numerics
	out["ac"] += int(_get_mod_value(modifier_system, unit_id, "ac_bonus"))
	out["speed"] += float(_get_mod_value(modifier_system, unit_id, "speed"))

	# Saves and checks
	var abil := ["STR","DEX","CON","INT","WIS","CHA"]
	for a in abil:
		out["save_mods"][a] += int(_get_mod_value(modifier_system, unit_id, "save:" + a))

	out["check_mods"]["Stealth"] += int(_get_mod_value(modifier_system, unit_id, "check:Stealth"))
	out["check_mods"]["Perception"] += int(_get_mod_value(modifier_system, unit_id, "check:Perception"))
	out["passive_perception"] = 10 + out["check_mods"]["Perception"]

	# Advantage / flags
	var adv_init = _get_flag(modifier_system, unit_id, "advantage:initiative")
	if adv_init:
		# Keep as a future tooltip/explain flag; initiative_mod stays numerical here
		pass
	out["concentration_advantage"] = _get_flag(modifier_system, unit_id, "advantage:concentration")

	# Damage traits merge (treat as sets)
	out["resistances"] = _merge_types(out["resistances"], _get_list(modifier_system, unit_id, "resistance:*"))
	out["immunities"] = _merge_types(out["immunities"], _get_list(modifier_system, unit_id, "immunity:*"))
	out["vulnerabilities"] = _merge_types(out["vulnerabilities"], _get_list(modifier_system, unit_id, "vulnerability:*"))


static func _merge_types(existing: Array, extra: Array) -> Array:
	var set: Dictionary = {}
	for t in existing:
		set[t] = true
	for t in extra:
		set[t] = true
	return set.keys()


static func _get_mod_value(modifier_system: Node, unit_id: String, key: String) -> float:
	if modifier_system.has_method("get_total"):
		var v = modifier_system.call("get_total", unit_id, key)
		return float(v) if v != null else 0.0
	return 0.0


static func _get_flag(modifier_system: Node, unit_id: String, key: String) -> bool:
	# Prefer explicit boolean API if available
	if modifier_system.has_method("get_flag"):
		var v = modifier_system.call("get_flag", unit_id, key)
		return (v == true) if v != null else false
	# Fallback to numeric > 0
	return _get_mod_value(modifier_system, unit_id, key) > 0.0


static func _get_list(modifier_system: Node, unit_id: String, prefix_key: String) -> Array:
	if modifier_system.has_method("get_list"):
		var v = modifier_system.call("get_list", unit_id, prefix_key)
		return v if v is Array else []
	return []


static func _deep_copy(d: Variant) -> Variant:
	if d is Dictionary:
		var out: Dictionary = {}
		for k in d.keys():
			out[k] = _deep_copy(d[k])
		return out
	elif d is Array:
		var arr: Array = []
		for v in d:
			arr.append(_deep_copy(v))
		return arr
	return d
