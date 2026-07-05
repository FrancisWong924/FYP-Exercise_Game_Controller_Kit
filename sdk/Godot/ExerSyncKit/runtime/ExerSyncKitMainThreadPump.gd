extends Node
## Drains WebSocket text lines on the Godot main thread.
## Autoload name: ExerSyncKitMainThreadPump (see project.godot).

var _inputs: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func register_input(input) -> void:
	if input == null or _inputs.has(input):
		return
	_inputs.append(input)


func unregister_input(input) -> void:
	if input == null:
		return
	_inputs.erase(input)


func _process(_delta: float) -> void:
	for input in _inputs.duplicate():
		if input != null and input.has_method("poll_socket"):
			input.poll_socket()
			input.process_pending_lines()
