# res://Systems/RollService.gd
extends Node

# Deterministic RNG dedicated to RollService.
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _seed: int = 12345						# safe default so tests don't warn

# Cached references for convenience (resolved at _ready).
var _event_bus: Node = null					# [[Managers/EventBus]] autoload
var _save_load: Node = null					# [[Managers/SaveLoadService]] autoload
var _modifier_system: Node = null			# [[Systems/ModifierSystem]] (node or autoload)
var _ac_service: Node = null				# [[Systems/ArmorClassService]] (optional)

func _ready() -> void:
	# Locate common services safely.
	_event_bus = get_node_or_null("/root/EventBus")
	_save_load = get_node_or_null("/root/SaveLoadService")

	# ModifierSystem can be an autoload or a child under Systems; check common spots.
	_modifier_system = get_node_or_null("/root/ModifierSystem")
	if _modifier_system == null:
		# Try a typical scene path (adjust if your layout differs).
		_modifier_system = get_node_or_null("../ModifierSystem") if has_node("../ModifierSystem") else null

	# ArmorClassService is optional; resolve if present.
	_ac_service = get_node_or_null("/root/ArmorClassService")
	if _ac_service == null:
		_ac_service = get_node_or_null("../ArmorClassService") if has_node("../ArmorClassService") else null

	# Seed deterministically from SaveLoadService when available, otherwise keep default.
	if _save_load != null and _save_load.has_method("get_rng_seed"):
		var s: int = int(_save_load.get_rng_seed())
		set_seed(s)
	else:
		set_seed(_seed)		# use existing default

	# Put this node in helpful groups for discovery.
	add_to_group("Systems")
	add_to_group("RollService")
	_log_where_modifier_system_came_from()


# ────────────────────────────────────────────────────────────────────────────
# RNG controls (deterministic across runs if you reuse the same seed)
# ────────────────────────────────────────────────────────────────────────────

func set_seed(seed: int) -> void:
	# Set internal seed and RNG state.
	_seed = seed
	_rng.seed = _seed

	# Persist to SaveLoadService if present.
	if _save_load != null and _save_load.has_method("set_rng_seed"):
		_save_load.set_rng_seed(_seed)

func get_seed() -> int:
	return _seed


# ────────────────────────────────────────────────────────────────────────────
# Public API
# ctx is a Dictionary; we defensive-default all fields to avoid null warnings.
# adv_override: -1 (disadv), 0 (normal), +1 (adv)
# ────────────────────────────────────────────────────────────────────────────

func roll_d20(ctx: Dictionary, adv_override: int = 0) -> Dictionary:
	var attacker_id: StringName = StringName(ctx.get("attacker_id", ""))
	var tags: Array = ctx.get("tags", []) as Array

	# Ask ModifierSystem for advantage context; use a conservative key.
	var adv_from_mods: int = _get_advantage(attacker_id, tags)

	var adv: int = adv_override if adv_override != 0 else adv_from_mods
	adv = clamp(adv, -1, 1)

	var die1: int = _roll_d20_single()
	var die2: int = 0
	var picked: int = die1

	if adv != 0:
		die2 = _roll_d20_single()
		picked = max(die1, die2) if adv > 0 else min(die1, die2)

	var result: int = picked
	var crit: bool = result == 20
	var fumble: bool = result == 1

	var payload: Dictionary = {
		"die": result,
		"adv": adv,
		"crit": crit,
		"fumble": fumble,
		# keep a small breakdown useful for logs/tools
		"rolls": [die1] if adv == 0 else [die1, die2],
		"sources": {
			"base": 0,								# base adds nothing to the die
			"modifier_system": 0,					# only d20 here; modifiers come in attack/check/save
			"context": {"adv_override": adv_override, "tags": tags.duplicate()}
		}
	}

	_emit_roll("d20", payload)
	_persist_rng_state()
	return payload


func attack_roll(ctx: Dictionary) -> Dictionary:
	var attacker_id: StringName = StringName(ctx.get("attacker_id", ""))
	var defender_id: StringName = StringName(ctx.get("defender_id", ""))
	var tags: Array = ctx.get("tags", []) as Array

	# 1) Determine advantage (respect override if provided)
	var adv_override: int = int(ctx.get("adv_override", 0))
	var d20: Dictionary = roll_d20(ctx, adv_override)

	# 2) Compute attack modifiers (global + tag-specific)
	var mod_total_and_breakdown := _get_attack_modifiers(attacker_id, tags)
	var mod_total: int = int(mod_total_and_breakdown.total)
	var breakdown: Dictionary = mod_total_and_breakdown.breakdown

	# 3) Total result
	var total: int = int(d20.get("die", 0)) + mod_total

	# 4) Target AC
	var target_ac: int = int(ctx.get("target_ac", -1))
	if target_ac < 0:
		if _ac_service != null and _ac_service.has_method("get_ac_for"):
			target_ac = int(_ac_service.get_ac_for(defender_id, tags))
		else:
			target_ac = 10		# safe default when AC service is absent

	# 5) Hit logic (5e style: nat 20 always hits; nat 1 always misses)
	var crit: bool = bool(d20.get("crit", false))
	var fumble: bool = bool(d20.get("fumble", false))
	var hit: bool = true if crit else false if fumble else total >= target_ac

	var payload: Dictionary = {
		"kind": "attack",
		"attacker_id": attacker_id,
		"defender_id": defender_id,
		"tags": tags.duplicate(),
		"die": int(d20.get("die", 0)),
		"adv": int(d20.get("adv", 0)),
		"crit": crit,
		"fumble": fumble,
		"total": total,
		"modifier_breakdown": breakdown,
		"target_ac": target_ac,
		"hit": hit
	}

	_emit_roll("attack", payload)
	_persist_rng_state()
	return payload


func ability_check(ctx: Dictionary) -> Dictionary:
	var actor_id: StringName = StringName(ctx.get("attacker_id", ctx.get("actor_id", "")))
	var skill: String = str(ctx.get("skill", ctx.get("ability", "")))	# e.g., "Stealth" (primary), or fallback to raw ability label
	var tags: Array = ctx.get("tags", []) as Array
	var adv_override: int = int(ctx.get("adv_override", 0))

	var d20: Dictionary = roll_d20(ctx, adv_override)

	# Prefer "check:Skill", fall back to "check" if your ModifierSystem uses generic keys
	var key_main: String = "check:" + skill if skill != "" else "check"
	var mod_total_and_breakdown := _get_total_with_breakdown(actor_id, key_main, tags)
	var mod_total: int = int(mod_total_and_breakdown.total)
	var breakdown: Dictionary = mod_total_and_breakdown.breakdown

	var total: int = int(d20.get("die", 0)) + mod_total

	var payload: Dictionary = {
		"kind": "check",
		"actor_id": actor_id,
		"skill": skill,
		"tags": tags.duplicate(),
		"die": int(d20.get("die", 0)),
		"adv": int(d20.get("adv", 0)),
		"crit": bool(d20.get("crit", false)),		# checks typically ignore crit/fumble, but we pass through for logs
		"fumble": bool(d20.get("fumble", false)),
		"total": total,
		"modifier_breakdown": breakdown
	}

	_emit_roll("check", payload)
	_persist_rng_state()
	return payload


func saving_throw(ctx: Dictionary) -> Dictionary:
	var actor_id: StringName = StringName(ctx.get("attacker_id", ctx.get("actor_id", "")))
	var ability: String = str(ctx.get("ability", ""))
	var dc: int = int(ctx.get("dc", 10))
	var tags: Array = ctx.get("tags", []) as Array
	var adv_override: int = int(ctx.get("adv_override", 0))

	var d20: Dictionary = roll_d20(ctx, adv_override)
	var key_main: String = "save:" + ability if ability != "" else "save"

	var mod_total_and_breakdown := _get_total_with_breakdown(actor_id, key_main, tags)
	var mod_total: int = int(mod_total_and_breakdown.total)
	var breakdown: Dictionary = mod_total_and_breakdown.breakdown

	var total: int = int(d20.get("die", 0)) + mod_total
	var success: bool = total >= dc

	var payload: Dictionary = {
		"kind": "save",
		"actor_id": actor_id,
		"ability": ability,
		"dc": dc,
		"tags": tags.duplicate(),
		"die": int(d20.get("die", 0)),
		"adv": int(d20.get("adv", 0)),
		"crit": bool(d20.get("crit", false)),
		"fumble": bool(d20.get("fumble", false)),
		"total": total,
		"success": success,
		"modifier_breakdown": breakdown
	}

	_emit_roll("save", payload)
	_persist_rng_state()
	return payload


func roll_damage(formula: String, ctx: Dictionary) -> Dictionary:
	# Minimal "XdY+Z" parser
	var tags: Array = ctx.get("tags", []) as Array
	var x: int = 0
	var y: int = 0
	var z: int = 0

	var cleaned: String = formula.strip_edges()
	var plus_idx: int = cleaned.find("+")
	var core: String = cleaned if plus_idx == -1 else cleaned.substr(0, plus_idx)
	var bonus_str: String = "" if plus_idx == -1 else cleaned.substr(plus_idx + 1).strip_edges()

	var d_idx: int = core.find("d")
	if d_idx != -1:
		x = int(core.substr(0, d_idx))
		y = int(core.substr(d_idx + 1))
	else:
		# If no "d", treat as flat damage
		z = int(core)

	if bonus_str != "":
		z = int(bonus_str)

	x = max(0, x)
	y = max(0, y)

	var rolls: Array = []
	var sum_dice: int = 0
	for i in x:
		var r: int = _roll_die(y)
		rolls.append(r)
		sum_dice += r

	var total: int = sum_dice + z

	var payload: Dictionary = {
		"kind": "damage",
		"formula": formula,
		"tags": tags.duplicate(),
		"rolls": rolls,
		"bonus": z,
		"total": total
	}

	_emit_roll("damage", payload)
	_persist_rng_state()
	return payload


# ────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ────────────────────────────────────────────────────────────────────────────

func _roll_d20_single() -> int:
	return _roll_die(20)

func _roll_die(sides: int) -> int:
	var s: int = max(2, sides)	# avoid invalid dice
	return int(_rng.randi_range(1, s))

# Put this at class scope (anywhere above _get_advantage)
func _coerce_adv(v: Variant) -> int:
	# Convert bool/number to -1/0/+1
	if v is bool:
		return 1 if v else 0
	if v is int or v is float:
		var n: int = int(v)
		return 1 if n > 0 else (-1 if n < 0 else 0)
	return 0


func _get_advantage(attacker_id: StringName, tags: Array) -> int:
	# Ask ModifierSystem for advantage using the base key API.
	# ModifierSystem.get_advantage("attack") internally reads "advantage:attack" (canonical).
	if _modifier_system == null:
		return 0

	var best_adv: int = 0
	var keys: Array = ["attack"]	# base key
	for t in tags:
		keys.append("attack:" + str(t))

	for k in keys:
		if _modifier_system.has_method("get_advantage"):
			var v: int = int(_modifier_system.get_advantage(attacker_id, k))
			if abs(v) > abs(best_adv):
				best_adv = v

	return clamp(best_adv, -1, 1)

func _get_attack_modifiers(attacker_id: StringName, tags: Array) -> Dictionary:
	# Combine generic and tag-specific attack bonuses; return total + per-source breakdown
	var total: int = 0
	var breakdown: Dictionary = {
		"base": 0,
		"modifier_system": {},
		"context": {"tags": tags.duplicate()}
	}

	if _modifier_system == null:
		return {"total": total, "breakdown": breakdown}

	var keys: Array = ["advantage:attack", "advantage"]
	for t in tags:
		keys.append("advantage:attack:" + str(t))

	var ms_contrib: Dictionary = {}
	for k in keys:
		if _modifier_system.has_method("get_total"):
			var v: int = int(_modifier_system.get_total(attacker_id, k))
			if v != 0:
				ms_contrib[k] = v
				total += v

	breakdown["modifier_system"] = ms_contrib
	return {"total": total, "breakdown": breakdown}

func _get_total_with_breakdown(actor_id: StringName, main_key: String, tags: Array) -> Dictionary:
	var total: int = 0
	var breakdown: Dictionary = {
		"base": 0,
		"modifier_system": {},
		"context": {"main_key": main_key, "tags": tags.duplicate()}
	}

	if _modifier_system == null:
		return {"total": total, "breakdown": breakdown}

	var keys: Array = [main_key]
	for t in tags:
		keys.append(main_key + ":" + str(t))

	var ms_contrib: Dictionary = {}
	for k in keys:
		if _modifier_system.has_method("get_total"):
			var v: int = int(_modifier_system.get_total(actor_id, k))
			if v != 0:
				ms_contrib[k] = v
				total += v

	breakdown["modifier_system"] = ms_contrib
	return {"total": total, "breakdown": breakdown}

func _emit_roll(kind: String, payload: Dictionary) -> void:
	# Emit both via EventBus (preferred) and local signal if you later add one to this node.
	# EventBus conventions differ; we handle two common patterns safely.
	if _event_bus != null:
		# Pattern A: EventBus.emit(event_name, payload)
		if _event_bus.has_method("emit"):
			_event_bus.emit("roll_performed", {"kind": kind, "payload": payload})

func _persist_rng_state() -> void:
	# If SaveLoadService wants to track live RNG state, write it back.
	if _save_load != null and _save_load.has_method("set_rng_seed"):
		_save_load.set_rng_seed(_seed)

func _log_where_modifier_system_came_from() -> void:
	var where: String = "null"
	if _modifier_system != null:
		where = _modifier_system.get_path()
	print("[RollService] ModifierSystem ref:", where)

# DEBUG

func debug_probe_adv(attacker_id: StringName, tags: Array) -> void:
	print("[RollService] ADV probe for", attacker_id, "tags", tags)
	var keys: Array = [
		"advantage:attack",
		"advantage",
		"advantage:atk",   # ← add
		"atk",             # ← add
		"attack"           # ← add (some APIs take bare key)
	]
	for t in tags:
		keys.append("advantage:attack:" + str(t))
		keys.append("advantage:atk:" + str(t))   # ← add
	for k in keys:
		var gv: Variant = 0
		if _modifier_system and _modifier_system.has_method("get_advantage"):
			gv = _modifier_system.get_advantage(attacker_id, k)
		print("  ", k, "=>", gv)
