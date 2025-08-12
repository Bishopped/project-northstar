extends Node

# Global event bus for loosely-coupled communication between systems.
# Event names are StringName; payloads are Variant (any type).
# Listeners are stored as weak references to prevent leaks/crashes.

# event_name -> Array[Dictionary]:
#   { "ref": WeakRef, "method": String, "deferred": bool }
var _listeners: Dictionary = {}
var _is_emitting: bool = false

func _ready() -> void:
	# Safe defaults; nothing to do at boot.
	pass

func subscribe(event_name: StringName, target: Object, method: String, deferred: bool=false) -> void:
	# Register a listener for a named event.
	# 'deferred' will call the listener with call_deferred (safe during tree changes).
	if target == null or method == "":
		return
	if not _listeners.has(event_name):
		_listeners[event_name] = []
	var entry := {
		"ref": weakref(target),
		"method": method,
		"deferred": deferred
	}
	_listeners[event_name].append(entry)

func unsubscribe(event_name: StringName, target: Object, method: String) -> void:
	# Remove a specific listener for a named event.
	if not _listeners.has(event_name):
		return
	var arr: Array = _listeners[event_name]
	for i in range(arr.size() - 1, -1, -1):
		var e: Dictionary = arr[i]
		var obj = e["ref"].get_ref()
		if obj == null or (obj == target and String(e["method"]) == method):
			arr.remove_at(i)
	if arr.is_empty():
		_listeners.erase(event_name)

func unsubscribe_target(target: Object) -> void:
	# Convenience: remove all subscriptions for a given object (any event).
	if target == null:
		return
	for event_name in _listeners.keys():
		var arr: Array = _listeners[event_name]
		for i in range(arr.size() - 1, -1, -1):
			var e: Dictionary = arr[i]
			var obj = e["ref"].get_ref()
			if obj == null or obj == target:
				arr.remove_at(i)

func emit(event_name: StringName, payload: Variant=null) -> void:
	# Broadcast to all current subscribers.
	# We duplicate the listener array to avoid mutation issues during iteration.
	if not _listeners.has(event_name):
		return
	var snapshot: Array = _listeners[event_name].duplicate(true)
	_is_emitting = true
	for e in snapshot:
		var obj = e["ref"].get_ref()
		if obj == null:
			continue
		var method: String = e["method"]
		if e.get("deferred", false):
			# Pass both event name and payload for easy multi-event handlers.
			obj.call_deferred(method, event_name, payload)
		else:
			if obj.has_method(method):
				obj.call(method, event_name, payload)
	_is_emitting = false
	# Cleanup dead refs after emitting
	_prune_dead(event_name)

func has_subscribers(event_name: StringName) -> bool:
	return _listeners.has(event_name) and not (_listeners[event_name] as Array).is_empty()

func _prune_dead(event_name: StringName) -> void:
	if not _listeners.has(event_name):
		return
	var arr: Array = _listeners[event_name]
	for i in range(arr.size() - 1, -1, -1):
		var e: Dictionary = arr[i]
		if e["ref"].get_ref() == null:
			arr.remove_at(i)
	if arr.is_empty():
		_listeners.erase(event_name)
