extends Node

#	DataRegistryService
#	Autoload path: res://Managers/DataRegistry.gd
#	Purpose:
#		• Preload all game data catalogs (actions, spells, items, conditions, monsters, encounters, character templates, class progressions)
#		• Validate schema (unique id, required fields, tags array)
#		• Expose read-only getters, tag search, and list API
#		• Emit lifecycle events via Managers/EventBus: data_registry_ready, catalog_reloaded
#	Links:
#		• Managers/EventBus (broadcast lifecycle)
#		• Systems/ActionSystem (actions lookup)
#		• Systems/ModifierSystem (conditions/items/spells references)
#		• Systems/RollService (roll profiles by id/type)
#		• Managers/AIController (query by tag)
#		• Managers/EncounterDirector (encounter templates & monsters)

# ─────────────────────────────────────────────────────────────────────────────
# Catalog directory map (kind -> folder)
const DIRS : Dictionary = {
	"action": "res://data/actions/",
	"spell": "res://data/spells/",
	"item": "res://data/items/",
	"condition": "res://data/conditions/",
	"monster": "res://data/monsters/",
	"encounter": "res://data/encounters/",
	"character_template": "res://data/characters/",
	"class_progression": "res://data/classes/"
}

# Required fields that MUST exist on each resource (by convention)
const REQUIRED_FIELDS : PackedStringArray = ["id", "name", "tags"]

# In-memory catalogs: kind -> (id -> Resource)
var _catalogs : Dictionary = {}

# Duplicate ID aggregation at startup
var _duplicate_ids : Array = []

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	# Initialize all catalogs dictionaries to safe defaults
	for kind in DIRS.keys():
		_catalogs[kind] = {}

	# Load every catalog
	_load_all_catalogs()

	# After loading, report aggregated duplicates once
	if _duplicate_ids.size() > 0:
		push_error(_format_duplicate_report())

	# Broadcast that the data registry is ready for use
	_broadcast_eventbus("data_registry_ready", _build_counts_payload())

# ─────────────────────────────────────────────────────────────────────────────
# Public API (read-only)

func get_action(id : String) -> Resource:
	return _get_by_id("action", id)

func get_spell(id : String) -> Resource:
	return _get_by_id("spell", id)

func get_item(id : String) -> Resource:
	return _get_by_id("item", id)

func get_condition(id : String) -> Resource:
	return _get_by_id("condition", id)

func get_monster(id : String) -> Resource:
	return _get_by_id("monster", id)

func get_encounter(id : String) -> Resource:
	return _get_by_id("encounter", id)

func get_character_template(id : String) -> Resource:
	return _get_by_id("character_template", id)

func get_class_progression(id : String) -> Resource:
	return _get_by_id("class_progression", id)

func find_by_tag(kind : String, tag : String) -> Array:
	# Returns an array of deep-cloned resources that contain the tag
	var out : Array = []
	if not _catalogs.has(kind):
		push_warning("DataRegistry.find_by_tag: unknown kind '%s'." % kind)
		return out
	var lower_tag : String = tag.to_lower()
	for r in _catalogs[kind].values():
		var tags : Array = _get_tags(r)
		# Case-insensitive match
		var has_tag : bool = false
		for t in tags:
			if str(t).to_lower() == lower_tag:
				has_tag = true
				break
		if has_tag:
			out.append(_safe_clone(r))
	return out

func list_all(kind : String) -> Array:
	# Returns deep clones (so callers can't mutate the registry)
	var out : Array = []
	if not _catalogs.has(kind):
		push_warning("DataRegistry.list_all: unknown kind '%s'." % kind)
		return out
	for r in _catalogs[kind].values():
		out.append(_safe_clone(r))
	return out

# Editor/debug-only: hot reload a single catalog kind
func reload_catalog(kind : String) -> void:
	if not OS.is_debug_build() and not Engine.is_editor_hint():
		push_warning("DataRegistry.reload_catalog: blocked outside editor/debug.")
		return
	if not DIRS.has(kind):
		push_warning("DataRegistry.reload_catalog: unknown kind '%s'." % kind)
		return
	# Clear old entries
	_catalogs[kind].clear()
	# (Re)load
	_load_catalog(kind)
	# Notify via EventBus for live tooling / inspectors
	_broadcast_eventbus("catalog_reloaded", {"kind": kind, "count": _catalogs[kind].size()})
	# Optional local log
	print("[DataRegistry] Reloaded catalog '%s' with %d entries." % [kind, _catalogs[kind].size()])

# ─────────────────────────────────────────────────────────────────────────────
# Internal: core loading

func _load_all_catalogs() -> void:
	_duplicate_ids.clear()
	for kind in DIRS.keys():
		_load_catalog(kind)
	# Summary log
	var counts := _build_counts_payload()

func _load_catalog(kind : String) -> void:
	var dir_path : String = DIRS[kind]
	var files : PackedStringArray = _gather_resource_files(dir_path)
	for fpath in files:
		var res : Resource = load(fpath)
		if res == null:
			push_warning("[DataRegistry] Failed to load resource: %s" % fpath)
			continue
		# Schema sanity
		var id : String = _get_string_or_empty(res, "id")
		var name_field : String = _get_string_or_empty(res, "name")
		var tags : Array = _get_tags(res)

		var missing : Array = []
		if id == "":
			missing.append("id")
		if name_field == "":
			missing.append("name")
		if tags == null or typeof(tags) != TYPE_ARRAY:
			missing.append("tags")

		if missing.size() > 0:
			push_warning("[DataRegistry] Missing required field(s) %s in %s" % [str(missing), fpath])
			continue

		# Duplicate check
		if _catalogs[kind].has(id):
			_duplicate_ids.append({"kind": kind, "id": id, "path": fpath})
			continue

		_catalogs[kind][id] = res

# ─────────────────────────────────────────────────────────────────────────────
# Internal: helpers

func _gather_resource_files(dir_path : String) -> PackedStringArray:
	var out : PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir_path):
		push_warning("[DataRegistry] Directory not found: %s" % dir_path)
		return out
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("[DataRegistry] Unable to open: %s" % dir_path)
		return out

	dir.list_dir_begin()
	while true:
		var name : String = dir.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue
		var full : String = dir_path + name
		if dir.current_is_dir():
			# Optional: recurse into subfolders
			for sub in _gather_resource_files(full + "/"):
				out.append(sub)
		else:
			if name.ends_with(".tres") or name.ends_with(".res"):
				out.append(full)
	dir.list_dir_end()
	return out

func _get_by_id(kind : String, id : String) -> Resource:
	if not _catalogs.has(kind):
		push_warning("DataRegistry.get_by_id: unknown kind '%s'." % kind)
		return null
	if not _catalogs[kind].has(id):
		push_warning("DataRegistry.get_by_id: missing '%s' in kind '%s'." % [id, kind])
		return null
	# Deep-duplicate so the caller cannot mutate our master reference
	var src : Resource = _catalogs[kind][id]
	return _safe_clone(src)

func _safe_clone(res : Resource) -> Resource:
	if res == null:
		return null
	# Deep duplicate is sufficient; callers can modify without touching registry
	var dup : Resource = res.duplicate(true)
	return dup

func _get_string_or_empty(res : Resource, prop : String) -> String:
	if res == null:
		return ""
	if not res.has_method("get") and not res.has_method("get_property_list"):
		return ""
	# Prefer get(prop) if available
	var val = null
	if res.has_method("get"):
		val = res.get(prop)
	if val == null:
		# Fallback: try direct index (works for most Resources)
		val = res.get(prop)
	if val == null:
		return ""
	return str(val)

func _get_tags(res : Resource) -> Array:
	if res == null:
		return []
	var t = res.get("tags")
	if t == null:
		return []
	if typeof(t) != TYPE_ARRAY:
		return []
	return t

func _build_counts_payload() -> Dictionary:
	var counts : Dictionary = {}
	for kind in _catalogs.keys():
		counts[kind] = _catalogs[kind].size()
	return counts

func _format_duplicate_report() -> String:
	var lines : Array = []
	lines.append("[DataRegistry] Duplicate IDs detected at startup:")
	for d in _duplicate_ids:
		lines.append("  • kind=%s id=%s (%s)" % [d["kind"], d["id"], d["path"]])
	return String("\n").join(lines)

# ─────────────────────────────────────────────────────────────────────────────
# EventBus integration (be tolerant of EventBus API shape)
func _broadcast_eventbus(event_name : String, payload : Dictionary) -> void:
	if Engine.has_singleton("EventBus"):
		var eb = Engine.get_singleton("EventBus")
		# Try common patterns without crashing if not found.
		if eb.has_signal(event_name):
			# Signal style: emit_signal("event", payload)
			# If the signal expects args, pass payload.
			eb.emit_signal(event_name, payload)
			return
		if eb.has_method("publish"):
			eb.publish(event_name, payload)	# e.g., EventBus.publish(name, data)
			return
		if eb.has_method("broadcast"):
			eb.broadcast(event_name, payload)
			return
		if eb.has_method("emit"):
			eb.emit(event_name, payload)
			return
	# If no EventBus or unknown API, write a friendly log.
	print("[DataRegistry] (%s) %s" % [event_name, str(payload)])
