@tool
extends EditorPlugin

const AUTOLOAD_NAME := "ExerSyncKitMainThreadPump"
const AUTOLOAD_PATH := "res://addons/ExerSyncKit/runtime/ExerSyncKitMainThreadPump.gd"


func _enter_tree() -> void:
	if not ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	if ProjectSettings.has_setting("autoload/%s" % AUTOLOAD_NAME):
		var path: String = ProjectSettings.get_setting("autoload/%s" % AUTOLOAD_NAME)
		if path.get_file() == AUTOLOAD_PATH.get_file():
			remove_autoload_singleton(AUTOLOAD_NAME)
