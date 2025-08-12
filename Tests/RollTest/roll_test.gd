extends Node

@onready var roll: Node = $RollService
@onready var mods: Node = get_node("/root/ModifierSystem")

const OP_ADV: String = "advantage"

func _ready() -> void:
	if roll == null:
		push_error("RollService not found at $RollService")
		return

	roll.set_seed(12345)

	if mods.has_method("ensure_unit"):
		mods.ensure_unit("hero1")

	# Add advantage using the base key; add_modifier will normalize to "advantage:attack".
	mods.add_modifier("hero1", "attack", {
		"id": "faerie_fire",
		"op": OP_ADV,
		"value": true,
		"tags": [],
		"duration": {"rounds": 3},
		"applies_if": null,
		"priority": 0
	})

	# Read using base key (get_advantage will read canonical storage internally).
	var adv_now: int = 0
	if mods.has_method("get_advantage"):
		adv_now = int(mods.get_advantage("hero1", "attack"))
	print("[Test] adv_now:", adv_now)		# expect 1

	# Roll (should show ADV:1)
	var r_adv: Dictionary = roll.attack_roll({
		"attacker_id": "hero1",
		"defender_id": "gob1",
		"tags": ["attack","melee","slashing"],
		"target_ac": 14
	})
	print("ADV:", r_adv.adv, " DIE:", r_adv.die)

	var dmg: Dictionary = roll.roll_damage("2d6+3", {})
	print("DMG rolls:", dmg.rolls, " bonus:", dmg.bonus, " total:", dmg.total)
