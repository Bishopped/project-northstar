extends Node

# Returns the RollService node under this Systems root.
func get_roll_service() -> Node:
	# %RollService uses “Unique name in owner” — fast and resilient
	return %RollService
