extends Resource
class_name GenericDataStub

@export var id   : String = ""         # required by DataRegistry
@export var name : String = ""         # required by DataRegistry
@export var tags : Array[String] = []  # required by DataRegistry

# You can add temporary fields here if desired, but these 3 are all DataRegistry needs.
