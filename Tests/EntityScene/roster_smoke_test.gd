extends Node

var reg_count: int = 0
var unreg_count: int = 0

# Simple assert helper
func _assert(cond: bool, msg: String) -> void:
	if not cond:
		printerr("[TEST][FAIL] ", msg)
		get_tree().quit(1)

func _ready() -> void:
	print("[TEST] Roster smoke test starting…")

	# Connect signals using real methods (no lambda capture)
	if has_node("/root/UnitRoster"):
		if UnitRoster.has_signal("unit_registered"):
			UnitRoster.unit_registered.connect(_on_unit_registered)
		if UnitRoster.has_signal("unit_unregistered"):
			UnitRoster.unit_unregistered.connect(_on_unit_unregistered)

	# Let scene _ready() complete for existing entities
	await get_tree().process_frame

	# 1) Roster exists and has both units
	_assert(has_node("/root/UnitRoster"), "UnitRoster autoload missing")
	var all_ids: Array = UnitRoster.list_all()
	print("[TEST] list_all -> ", all_ids)
	_assert(all_ids.size() == 2, "Expected 2 units, got %d" % all_ids.size())
	_assert(all_ids.has("hero1"), "hero1 missing from list_all")
	_assert(all_ids.has("gob1"), "gob1 missing from list_all")

	# 2) Team buckets
	var party: Array = UnitRoster.list_team("party")
	var enemy: Array = UnitRoster.list_team("enemy")
	print("[TEST] party=", party, " enemy=", enemy)
	_assert(party.size() == 1 and party[0] == "hero1", "Party team not correct")
	_assert(enemy.size() == 1 and enemy[0] == "gob1", "Enemy team not correct")

	# 3) Spawn a temp unit using the real scene (so onready paths exist)
	var scene: PackedScene = load("res://core/entity/EntityRoot.tscn")
	var temp_root: Node = scene.instantiate()
	# Try to find the controller; if your controller is on the root, this returns null and we fall back.
	var ctrl: Node = temp_root.get_node_or_null("EntityController")
	ctrl = ctrl if ctrl != null else temp_root
	ctrl.unit_id = "temp_unit"
	ctrl.team = "enemy"
	get_tree().current_scene.add_child(temp_root)

	# wait two frames so autoloads & ready signals settle
	await get_tree().process_frame
	await get_tree().process_frame

	_assert(UnitRoster.exists("temp_unit"), "temp_unit failed to register")
	_assert(reg_count >= 1, "unit_registered did not fire for temp_unit")

	# 4) Despawn it and validate unregistration
	temp_root.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	_assert(!UnitRoster.exists("temp_unit"), "temp_unit failed to unregister")
	_assert(unreg_count >= 1, "unit_unregistered did not fire for temp_unit")

	print("[TEST][PASS] Roster counts, teams, and events OK")
	get_tree().quit(0)

func _on_unit_registered(uid: String) -> void:
	if uid == "temp_unit":
		reg_count += 1
		print("[TEST] unit_registered captured:", uid, " reg_count=", reg_count)

func _on_unit_unregistered(uid: String) -> void:
	if uid == "temp_unit":
		unreg_count += 1
		print("[TEST] unit_unregistered captured:", uid, " unreg_count=", unreg_count)
