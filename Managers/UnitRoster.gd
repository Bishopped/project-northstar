extends Node
signal unit_registered(unit_id: String)
signal unit_unregistered(unit_id: String)

var by_id: Dictionary = {}
var by_team: Dictionary = {}

var _event_bus: Node = null

func _ready() -> void:
	if has_node("/root/EventBus"):
		_event_bus = get_node("/root/EventBus")
	_subscribe_event_bus("entity_spawned", Callable(self, "_on_entity_spawned"))
	_subscribe_event_bus("entity_despawned", Callable(self, "_on_entity_despawned"))

func _subscribe_event_bus(event_name: String, handler: Callable) -> void:
	if _event_bus == null:
		return
	if _event_bus.has_signal(event_name):
		if not _event_bus.is_connected(event_name, handler):
			_event_bus.connect(event_name, handler)
		return
	if _event_bus.has_method("subscribe"):
		var target: Object = handler.get_object()
		var method_name: String = handler.get_method()
		if target != null and method_name != "":
			_event_bus.call("subscribe", event_name, target, method_name)
		else:
			_event_bus.call("subscribe", event_name, handler)

# API
func register_unit(entity: Node) -> void:
	var unit_id: String = _get_string_prop(entity, "unit_id", "")
	var team: String = _get_string_prop(entity, "team", "")
	if unit_id == "":
		return
	by_id[unit_id] = entity
	var key: String = team if team != "" else ""
	if not by_team.has(key):
		by_team[key] = []
	_add_unique_to_bucket(key, unit_id)
	_emit_local_and_bus("unit_registered", unit_id)

func unregister_unit(unit_id: String) -> void:
	if unit_id == "":
		return
	var changed := false
	if by_id.has(unit_id):
		by_id.erase(unit_id)
		changed = true
	for team_key in by_team.keys():
		var arr: Array = by_team[team_key]
		var idx := arr.find(unit_id)
		if idx != -1:
			arr.remove_at(idx)
			by_team[team_key] = arr
			changed = true
	if changed:
		_emit_local_and_bus("unit_unregistered", unit_id)

func get_unit(unit_id: String) -> Node:
	return by_id.get(unit_id, null)

func list_all() -> Array:
	return by_id.keys()

func list_team(team: String) -> Array:
	return by_team.get(team, [])

func exists(unit_id: String) -> bool:
	return by_id.has(unit_id)

func clear() -> void:
	by_id = {}
	by_team = {}

# Event handlers (tolerant signatures)
func _on_entity_spawned(a = null, b = null) -> void:
	var unit_id := ""
	if typeof(a) == TYPE_STRING:
		unit_id = String(a)
	elif typeof(a) == TYPE_DICTIONARY and a.has("unit_id"):
		unit_id = String(a["unit_id"])
	if unit_id == "":
		return
	var entity := _find_entity_controller_by_id(unit_id)
	if entity != null:
		register_unit(entity)

func _on_entity_despawned(a = null, b = null) -> void:
	var unit_id := ""
	if typeof(a) == TYPE_STRING:
		unit_id = String(a)
	elif typeof(a) == TYPE_DICTIONARY and a.has("unit_id"):
		unit_id = String(a["unit_id"])
	if unit_id == "":
		return
	unregister_unit(unit_id)

# Helpers
func _emit_local_and_bus(event_name: String, unit_id: String) -> void:
	if event_name == "unit_registered":
		unit_registered.emit(unit_id)
	elif event_name == "unit_unregistered":
		unit_unregistered.emit(unit_id)
	if _event_bus == null:
		return
	if _event_bus.has_signal(event_name):
		_event_bus.emit_signal(event_name, unit_id)
	elif _event_bus.has_method("publish"):
		_event_bus.call("publish", event_name, unit_id)

func _add_unique_to_bucket(team: String, unit_id: String) -> void:
	var arr: Array = by_team.get(team, [])
	if arr.find(unit_id) == -1:
		arr.append(unit_id)
	by_team[team] = arr

func _find_entity_controller_by_id(unit_id: String) -> Node:
	if by_id.has(unit_id):
		return by_id[unit_id]
	var root: Node = get_tree().get_current_scene()
	if root == null:
		root = get_tree().root
	if root == null:
		return null
	return _dfs_find_by_property(root, "unit_id", unit_id)

func _dfs_find_by_property(n: Node, prop: String, value: String) -> Node:
	if _has_property(n, prop):
		var v = n.get(prop)
		if typeof(v) == TYPE_STRING and String(v) == value:
			return n
	for c in n.get_children():
		if c is Node:
			var found := _dfs_find_by_property(c, prop, value)
			if found != null:
				return found
	return null

func _has_property(obj: Object, prop: String) -> bool:
	for pd in obj.get_property_list():
		if pd.has("name") and String(pd["name"]) == prop:
			return true
	return false

func _get_string_prop(obj: Object, prop: String, fallback: String) -> String:
	if _has_property(obj, prop):
		var v: Variant = obj.get(prop)
		if typeof(v) == TYPE_STRING:
			return String(v)
	return fallback
