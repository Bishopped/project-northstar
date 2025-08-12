## res://Systems/ModifierSystem.gd
## Central authority for runtime modifiers per [[Systems/ModifierSystem]].
## Serves [[Systems/RollService]], [[Runtime/StatBlock]], [[Systems/DamageService]].
## Consumes [[Managers/ConditionManager]], [[Runtime/EquipmentState]], [[Systems/EffectResolver]], [[Systems/LevelUpSystem]].
## Emits events via [[Managers/EventBus]]: "modifier_changed(unit_id, key)", optional "modifiers_cleared(unit_id)".

extends Node
class_name NS_ModifierSystem   # Different from Autoload name "ModifierSystem" to avoid name collision.

# ─────────────────────────────────────────────────────────────────────────────
# Data model:
# _data = {
# 	"unit_id": {
# 		"key": [ { id, op, value, tags, duration, applies_if, priority, _remaining_seconds, _remaining_rounds, _duration_type }, ... ]
# 	}
# }
#
# Keys examples:
# 	"attack_bonus", "damage_bonus:fire", "ac_bonus", "save:DEX", "check:Stealth", "speed",
# 	"advantage:attack", "resistance:fire", "immunity:poison", "vulnerability:slashing"
#
# Supported ops:
# 	"add", "mul", "set_min", "set_max",
# 	"advantage", "disadvantage",
# 	"grant_resistance", "grant_immunity", "grant_vulnerability"
# ─────────────────────────────────────────────────────────────────────────────

var _data : Dictionary = {}		# unit_id → key → Array[Dictionary]
var _units_cached_keys : Dictionary = {}	# unit_id → Set (Dictionary keys present), for quick presence checks

# Internal constants for op strings to avoid typos
const OP_ADD : String = "add"
const OP_MUL : String = "mul"
const OP_SET_MIN : String = "set_min"
const OP_SET_MAX : String = "set_max"
const OP_ADV : String = "advantage"
const OP_DIS : String = "disadvantage"
const OP_GRANT_RES : String = "grant_resistance"
const OP_GRANT_IMM : String = "grant_immunity"
const OP_GRANT_VULN : String = "grant_vulnerability"

# Duration handling
# "duration" can be one of:
# 	null → persistent
# 	{ "seconds": float } → second-based; counts down via tick_durations(delta_seconds)
# 	{ "rounds": int } → combat round-based; counts down via tick_durations(_, true)
# 	{ "scene": true } → cleared via clear_unit(...) or scene transition hooks (not implemented here)
#
# We'll copy fields to internal _remaining_seconds / _remaining_rounds for runtime countdown.
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Initialize root dictionaries to avoid null warnings.
	_data = {}
	_units_cached_keys = {}

# ─────────────────────────────────────────────────────────────────────────────
# Public API (minimum)
# ─────────────────────────────────────────────────────────────────────────────

func add_modifier(unit_id : String, key : String, src : Dictionary) -> void:
	# Adds or replaces a source (same source.id) under unit_id/key.
	# Expected src fields: id:String, op:String, value:float|int|bool, tags:Array, duration:Dictionary|null,
	# applies_if:Array|Null, priority:int
	# See [[Systems/ModifierSystem]] for shape.
	if unit_id == "" or key == "":
		return

	var entry : Dictionary = _sanitize_source(src)
	if entry.is_empty():
		return

	if not _data.has(unit_id):
		_data[unit_id] = {}
	if not _data[unit_id].has(key):
		_data[unit_id][key] = []

	# Replace existing with same id, else append
	var list : Array = _data[unit_id][key]
	var replaced : bool = false
	for i in list.size():
		var existing : Dictionary = list[i]
		if str(existing.get("id", "")) == entry.get("id", ""):
			list[i] = entry
			replaced = true
			break
	if not replaced:
		list.append(entry)

	# Maintain cached keys
	if not _units_cached_keys.has(unit_id):
		_units_cached_keys[unit_id] = {}
	_units_cached_keys[unit_id][key] = true

	_emit_changed(unit_id, key)

func remove_modifier(unit_id : String, key : String, source_id : String) -> bool:
	# Removes a specific source by id. Returns true if removed.
	if not _data.has(unit_id):
		return false
	if not _data[unit_id].has(key):
		return false

	var list : Array = _data[unit_id][key]
	var removed : bool = false
	for i in range(list.size() - 1, -1, -1):
		var entry : Dictionary = list[i]
		if str(entry.get("id", "")) == source_id:
			list.remove_at(i)
			removed = true
			break

	if removed:
		if list.is_empty():
			_data[unit_id].erase(key)
			if _units_cached_keys.has(unit_id):
				_units_cached_keys[unit_id].erase(key)
		_emit_changed(unit_id, key)
	return removed

func get_total(unit_id : String, key : String, default_value : float = 0.0) -> float:
	# Computes total using stacking rules: add sums, mul multiplies, then set_min/set_max applied last.
	# Advantage/disadvantage and flags are NOT part of get_total—query via get_advantage/has_resistance/...
	if not _data.has(unit_id):
		return default_value
	if not _data[unit_id].has(key):
		return default_value

	var list : Array = _data[unit_id][key]
	if list.is_empty():
		return default_value

	var add_sum : float = 0.0
	var mul_prod : float = 1.0
	var mins : Array = []
	var maxs : Array = []

	for entry in list:
		if not _entry_applies(entry):
			continue
		var op : String = str(entry.get("op", ""))
		var v = entry.get("value", 0.0)
		var val : float = float(v) if (v is float or v is int) else 0.0

		match op:
			OP_ADD:
				add_sum += val
			OP_MUL:
				mul_prod *= val
			OP_SET_MIN:
				mins.append(entry)
			OP_SET_MAX:
				maxs.append(entry)
			_:
				# Ignore non-scalar ops here
				pass

	var total : float = (default_value + add_sum) * mul_prod

	# Apply set_min/set_max last, using priority to tie-break.
	if mins.size() > 0:
		var min_val : float = _resolve_bound(mins, true)
		if total < min_val:
			total = min_val
	if maxs.size() > 0:
		var max_val : float = _resolve_bound(maxs, false)
		if total > max_val:
			total = max_val

	return total

func get_advantage(unit_id : String, key : String) -> int:
	# Returns -1 (disadvantage), 0 (neutral), +1 (advantage)
	# We expect the storage key to be "advantage:<key>"
	var adv_key : String = "advantage:%s" % key
	if not _data.has(unit_id) or not _data[unit_id].has(adv_key):
		return 0

	var list : Array = _data[unit_id][adv_key]
	var adv_count : int = 0
	var dis_count : int = 0

	for entry in list:
		if not _entry_applies(entry):
			continue
		var op : String = str(entry.get("op", ""))
		match op:
			OP_ADV:
				adv_count += 1
			OP_DIS:
				dis_count += 1
			_:
				pass

	if adv_count > dis_count:
		return 1
	elif dis_count > adv_count:
		return -1
	return 0

func has_resistance(unit_id : String, dmg_type : String) -> bool:
	# Immunity > Resistance > Vulnerability. This checks resistance only; callers should handle the full hierarchy
	# or use the helper resolve_damage_relation below if needed by [[Systems/DamageService]].
	return _has_flag(unit_id, "resistance:%s" % dmg_type, OP_GRANT_RES)

func has_immunity(unit_id : String, dmg_type : String) -> bool:
	return _has_flag(unit_id, "immunity:%s" % dmg_type, OP_GRANT_IMM)

func has_vulnerability(unit_id : String, dmg_type : String) -> bool:
	return _has_flag(unit_id, "vulnerability:%s" % dmg_type, OP_GRANT_VULN)

func clear_unit(unit_id : String) -> void:
	if _data.has(unit_id):
		_data.erase(unit_id)
	if _units_cached_keys.has(unit_id):
		_units_cached_keys.erase(unit_id)
	_emit_cleared(unit_id)

func tick_durations(delta_seconds : float, in_combat_round_advance : bool = false) -> void:
	# Decrements timers and expires finished sources. Emits modifier_changed for affected keys.
	# Should be called by [[Managers/ConditionManager]] or your global tick/turn manager.
	var changed : Array = []	# Array of { unit_id, key }

	for unit_id in _data.keys():
		var unit_map : Dictionary = _data[unit_id]
		for key in unit_map.keys():
			var list : Array = unit_map[key]
			var expired_any : bool = false

			for i in range(list.size() - 1, -1, -1):
				var entry : Dictionary = list[i]
				var t : String = str(entry.get("_duration_type", ""))

				if t == "seconds":
					var rem : float = float(entry.get("_remaining_seconds", 0.0))
					rem -= max(delta_seconds, 0.0)
					entry["_remaining_seconds"] = rem
					if rem <= 0.0:
						list.remove_at(i)
						expired_any = true

				elif t == "rounds" and in_combat_round_advance:
					var r : int = int(entry.get("_remaining_rounds", 0))
					r -= 1
					entry["_remaining_rounds"] = r
					if r <= 0:
						list.remove_at(i)
						expired_any = true

				elif t == "scene":
					# Left to be cleared on scene end; no per-tick behavior.
					pass

			if expired_any:
				if list.is_empty():
					unit_map.erase(key)
					if _units_cached_keys.has(unit_id):
						_units_cached_keys[unit_id].erase(key)
				changed.append({ "unit_id": unit_id, "key": key })

	# Emit after mutation is complete
	for ch in changed:
		_emit_changed(str(ch["unit_id"]), str(ch["key"]))

# ─────────────────────────────────────────────────────────────────────────────
# Debug / Testing helpers
# ─────────────────────────────────────────────────────────────────────────────

func list_sources(unit_id : String, key : String) -> Array:
	# Deep copy to keep internal state safe
	if not _data.has(unit_id) or not _data[unit_id].has(key):
		return []
	return _data[unit_id][key].duplicate(true)

func debug_apply_demo_set(unit_id : String) -> void:
	# Attaches a representative set of modifiers for testing.
	# Used by the test scene. References [[Systems/ModifierSystem]] acceptance tests.
	add_modifier(unit_id, "attack_bonus", {
		"id": "bless",
		"op": OP_ADD,
		"value": 1.0,
		"tags": [],
		"duration": { "rounds": 10 },
		"applies_if": null,
		"priority": 0
	})
	add_modifier(unit_id, "ac_bonus", {
		"id": "shield_of_faith",
		"op": OP_ADD,
		"value": 2.0,
		"tags": [],
		"duration": { "seconds": 600.0 },
		"applies_if": null,
		"priority": 0
	})
	add_modifier(unit_id, "advantage:attack", {
		"id": "faerie_fire",
		"op": OP_ADV,
		"value": true,
		"tags": [],
		"duration": { "rounds": 3 },
		"applies_if": null,
		"priority": 0
	})
	add_modifier(unit_id, "resistance:fire", {
		"id": "ring_of_fire_resistance",
		"op": OP_GRANT_RES,
		"value": true,
		"tags": [ "equipment" ],
		"duration": null,
		"applies_if": null,
		"priority": 10
	})
	add_modifier(unit_id, "attack_bonus", {
		"id": "hex_penalty_example",
		"op": OP_ADD,
		"value": -1.0,
		"tags": [ "curse" ],
		"duration": { "rounds": 5 },
		"applies_if": null,
		"priority": 0
	})
	add_modifier(unit_id, "attack_bonus", {
		"id": "belt_of_giant_strength_cap",
		"op": OP_SET_MIN,
		"value": 5.0,
		"tags": [ "equipment" ],
		"duration": null,
		"applies_if": null,
		"priority": 1
	})

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

func _sanitize_source(src : Dictionary) -> Dictionary:
	# Ensures required fields, sets runtime counters for durations, avoids null warnings.
	var out : Dictionary = {}

	var idv = src.get("id", "")
	if str(idv) == "":
		return {}	# invalid

	var opv : String = str(src.get("op", ""))
	if opv == "":
		return {}

	var valuev = src.get("value", 0.0)
	# Allow bool/int/float. Coerce unknowns to 0.0 or false.
	if not (valuev is bool or valuev is int or valuev is float):
		valuev = 0.0

	var tagsv : Array = src.get("tags", [])
	if tagsv == null:
		tagsv = []

	var durationv = src.get("duration", null)
	var applies_if_v = src.get("applies_if", null)
	var priorityv : int = int(src.get("priority", 0))

	out["id"] = str(idv)
	out["op"] = opv
	out["value"] = valuev
	out["tags"] = tagsv
	out["duration"] = durationv
	out["applies_if"] = applies_if_v
	out["priority"] = priorityv

	# Normalize duration
	out["_duration_type"] = ""
	out["_remaining_seconds"] = 0.0
	out["_remaining_rounds"] = 0

	if durationv == null:
		# Persistent
		out["_duration_type"] = ""
	elif typeof(durationv) == TYPE_DICTIONARY:
		if durationv.has("seconds"):
			out["_duration_type"] = "seconds"
			out["_remaining_seconds"] = float(durationv["seconds"])
		elif durationv.has("rounds"):
			out["_duration_type"] = "rounds"
			out["_remaining_rounds"] = int(durationv["rounds"])
		elif durationv.has("scene") and bool(durationv["scene"]):
			out["_duration_type"] = "scene"
		else:
			# Unknown dict shape → treat as persistent
			out["_duration_type"] = ""
	else:
		# Unknown type → persistent
		out["_duration_type"] = ""

	return out

func _entry_applies(entry : Dictionary) -> bool:
	# Placeholder for applies_if; for now, we apply by default.
	# Later, integrate with tag/condition predicates driven by [[Managers/ConditionManager]] or a query context.
	return true

func _resolve_bound(entries : Array, is_min : bool) -> float:
	# Resolve set_min/set_max arrays with priority tie-break.
	# Priority: higher "priority" wins. If equal priority, pick "more constraining":
	#  - For min: pick the highest value (more constraining lower bound)
	#  - For max: pick the lowest value (more constraining upper bound)
	var best : Dictionary = {}
	var best_pri : int = -2147483648
	for e in entries:
		if not _entry_applies(e):
			continue
		var pri : int = int(e.get("priority", 0))
		var v = e.get("value", 0.0)
		var val : float = float(v) if (v is float or v is int) else 0.0

		if pri > best_pri:
			best = e
			best_pri = pri
		elif pri == best_pri and not best.is_empty():
			var best_val : float = float(best.get("value", 0.0))
			if is_min:
				best = e if val > best_val else best
			else:
				best = e if val < best_val else best

	# Fallback if no applicable entries
	return float(best.get("value", 0.0)) if not best.is_empty() else (0.0 if is_min else 1e30)

func _has_flag(unit_id : String, full_key : String, expected_op : String) -> bool:
	if not _data.has(unit_id) or not _data[unit_id].has(full_key):
		return false
	var list : Array = _data[unit_id][full_key]
	var has_flagv : bool = false
	var best_pri : int = -2147483648
	var found_immunity : bool = false
	var found_resistance : bool = false
	var found_vulnerability : bool = false

	# Scan all; record top precedence and priority
	for e in list:
		if not _entry_applies(e):
			continue
		var op : String = str(e.get("op", ""))
		var pri : int = int(e.get("priority", 0))

		match op:
			OP_GRANT_IMM:
				# Immunity dominates regardless of priority vs others
				found_immunity = true
			OP_GRANT_RES:
				if pri > best_pri:
					found_resistance = true
					best_pri = pri
			OP_GRANT_VULN:
				if pri > best_pri:
					found_vulnerability = true
					best_pri = pri
			_:
				pass

	# Immunity > Resistance > Vulnerability precedence for presence checks
	if expected_op == OP_GRANT_IMM:
		return found_immunity
	elif expected_op == OP_GRANT_RES:
		return (not found_immunity) and found_resistance
	elif expected_op == OP_GRANT_VULN:
		return (not found_immunity) and (not found_resistance) and found_vulnerability

	return false

func _emit_changed(unit_id : String, key : String) -> void:
	# Try common EventBus shapes; keep loose coupling with [[Managers/EventBus]].
	if typeof(EventBus) != TYPE_NIL:
		if EventBus.has_signal("modifier_changed"):
			EventBus.emit_signal("modifier_changed", unit_id, key)
		elif EventBus.has_method("publish"):
			EventBus.publish("modifier_changed", { "unit_id": unit_id, "key": key })
		elif EventBus.has_signal("modifier_changed"):
			EventBus.emit_signal("modifier_changed", unit_id, key)

func _emit_cleared(unit_id : String) -> void:
	if typeof(EventBus) != TYPE_NIL:
		if EventBus.has_method("emit"):
			EventBus.emit("modifiers_cleared", unit_id)
		elif EventBus.has_method("publish"):
			EventBus.publish("modifiers_cleared", { "unit_id": unit_id })
		elif EventBus.has_signal("modifiers_cleared"):
			EventBus.emit_signal("modifiers_cleared", unit_id)
