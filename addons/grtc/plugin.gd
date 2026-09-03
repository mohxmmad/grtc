tool
extends EditorPlugin

var dock = null
var button = null
var dock_slot = DOCK_SLOT_RIGHT_UL

func _enter_tree():
	dock = preload("res://addons/grtc/grtc_dock.gd").new()
	dock.set_editor_interface(get_editor_interface())
	dock.name = "GRTC"
	add_control_to_dock(dock_slot, dock)

	button = ToolButton.new()
	button.text = "GRTC Sync"
	button.connect("pressed", self, "_toggle_window")
	add_control_to_container(CONTAINER_TOOLBAR, button)

func _exit_tree():
	if button:
		remove_control_from_container(CONTAINER_TOOLBAR, button)
		button.queue_free()
		button = null
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
	dock = null

func _toggle_window():
	if dock == null:
		return
	if dock.visible:
		dock.hide()
	else:
		dock.show()
