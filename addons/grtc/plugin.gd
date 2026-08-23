tool
extends EditorPlugin

var dock = null
var window = null
var button = null

func _enter_tree():
	dock = preload("res://addons/grtc/grtc_dock.gd").new()
	dock.set_editor_interface(get_editor_interface())

	window = WindowDialog.new()
	window.name = "GRTC"
	window.rect_min_size = Vector2(700, 520)
	window.window_title = "GRTC"
	window.add_child(dock)
	get_editor_interface().get_base_control().add_child(window)

	button = ToolButton.new()
	button.text = "GRTC"
	button.connect("pressed", self, "_toggle_window")
	add_control_to_container(CONTAINER_TOOLBAR, button)

func _exit_tree():
	if button:
		remove_control_from_container(CONTAINER_TOOLBAR, button)
		button.queue_free()
		button = null
	if window:
		window.queue_free()
		window = null
	dock = null

func _toggle_window():
	if window == null:
		return
	if window.visible:
		window.hide()
	else:
		window.popup_centered_ratio(0.7)
