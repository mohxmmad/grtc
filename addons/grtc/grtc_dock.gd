tool
extends VBoxContainer

const SERVER_DEFAULT = "http://localhost:8000"

var _http = null
var _git = preload("res://addons/grtc/grtc_git_helper.gd").new()
var _editor_interface = null

var _busy = false

var _server_url = SERVER_DEFAULT
var _user_email = ""
var _session_id = ""
var _user_id = ""
var _github_username = ""
var _project_path = ""
var _current_repo_url = ""
var _github_token = ""

var _status_label = null
var _server_edit = null
var _email_edit = null
var _session_edit = null
var _user_id_edit = null
var _username_edit = null
var _project_path_edit = null
var _repo_url_edit = null
var _github_token_edit = null

func set_editor_interface(editor_interface):
	_editor_interface = editor_interface

func _ready():
	_build_ui()
	_load_state()
	_refresh_fields()
	_set_status("Ready")

func _exit_tree():
	_save_state()

func _build_ui():
	var title = Label.new()
	title.text = "GRTC Collaboration"
	add_child(title)

	var help = Label.new()
	help.autowrap = true
	help.text = "Godot editor-side GRTC panel. Login opens the backend OAuth page; Git push/pull runs locally from the current project folder."
	add_child(help)

	_status_label = Label.new()
	_status_label.autowrap = true
	_status_label.rect_min_size = Vector2(0, 42)
	add_child(_status_label)

	parent_add(_row_line_edit("Server URL", true, _server_url, self, "_on_server_url_changed"), self)
	_server_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("Your Email", true, _user_email, self, "_on_email_changed"), self)
	_email_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("Session ID", true, _session_id, self, "_on_session_changed"), self)
	_session_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("User ID", true, _user_id, self, "_on_user_id_changed"), self)
	_user_id_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("GitHub Username", true, _github_username, self, "_on_username_changed"), self)
	_username_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("Project Path", true, _project_path, self, "_on_project_path_changed"), self)
	_project_path_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("Repository URL", true, _current_repo_url, self, "_on_repo_url_changed"), self)
	_repo_url_edit = get_child(get_child_count() - 1).get_child(1)
	parent_add(_row_line_edit("GitHub Token", true, _github_token, self, "_on_github_token_changed"), self)
	_github_token_edit = get_child(get_child_count() - 1).get_child(1)

	var actions = HBoxContainer.new()
	add_child(actions)
	_add_button(actions, "Login with GitHub", self, "_on_login_pressed")
	_add_button(actions, "Refresh Files", self, "_refresh_project_files")
	_add_button(actions, "Open Repository", self, "_open_repository")
	_add_button(actions, "Push Changes", self, "_on_push_pressed")
	_add_button(actions, "Pull Changes", self, "_on_pull_pressed")

func parent_add(node, _owner):
	add_child(node)

func _row_line_edit(label_text, editable, value, target, method_name):
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.rect_min_size = Vector2(130, 0)
	row.add_child(label)

	var edit = LineEdit.new()
	edit.text = value
	edit.editable = editable
	edit.size_flags_horizontal = SIZE_EXPAND_FILL
	if target != null and method_name != "":
		edit.connect("text_changed", target, method_name)
	row.add_child(edit)
	return row

func _add_button(parent, text, target, method_name):
	var button = Button.new()
	button.text = text
	button.connect("pressed", target, method_name)
	button.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(button)
	return button

func _refresh_fields():
	_set_line_edit(_server_edit, _server_url)
	_set_line_edit(_email_edit, _user_email)
	_set_line_edit(_session_edit, _session_id)
	_set_line_edit(_user_id_edit, _user_id)
	_set_line_edit(_username_edit, _github_username)
	_set_line_edit(_project_path_edit, _project_path)
	_set_line_edit(_repo_url_edit, _current_repo_url)
	_set_line_edit(_github_token_edit, _github_token)

func _set_line_edit(node, value):
	if node and node.text != value:
		node.text = value

func _set_status(message, is_error=false):
	if _status_label:
		var prefix = "Status: "
		var color = Color(0.75, 1, 0.75)
		if is_error:
			prefix = "Error: "
			color = Color(1, 0.4, 0.4)
		_status_label.text = prefix + message
		_status_label.add_color_override("font_color", color)

func _on_server_url_changed(text):
	_server_url = text.strip_edges()
	_save_state()

func _on_email_changed(text):
	_user_email = text.strip_edges()
	_save_state()

func _on_session_changed(text):
	_session_id = text.strip_edges()
	_save_state()

func _on_user_id_changed(text):
	_user_id = text.strip_edges()
	_save_state()

func _on_username_changed(text):
	_github_username = text.strip_edges()
	_save_state()

func _on_project_path_changed(text):
	_project_path = text.strip_edges()
	_save_state()

func _on_repo_url_changed(text):
	_current_repo_url = text.strip_edges()
	_save_state()

func _on_github_token_changed(text):
	_github_token = text.strip_edges()
	_save_state()

func _on_login_pressed():
	OS.shell_open(_server_url + "/github/login")
	_set_status("Opened GitHub login in your browser.")

func _on_push_pressed():
	if _busy:
		return
	var project_path = _project_root()
	if project_path == "":
		_set_status("Project path is required.", true)
		return
	if _current_repo_url == "" or _github_token == "":
		_set_status("Repository URL and GitHub token are required before pushing.", true)
		return
	_busy = true
	var author_name = _github_username if _github_username != "" else _fallback_username()
	var result = _git.execute_full_workflow(project_path, _current_repo_url, author_name, _user_email, _github_token, "Initial commit from Godot GRTC Panel")
	_busy = false
	if result.get("code", 0) == 0:
		_set_status("Changes pushed to GitHub.")
		_refresh_project_files()
	else:
		_set_status(_join_lines(result.get("output", ["Git push failed"])) , true)

func _on_pull_pressed():
	if _busy:
		return
	var project_path = _project_root()
	if project_path == "":
		_set_status("Project path is required.", true)
		return
	if _current_repo_url == "" or _github_token == "":
		_set_status("Repository URL and GitHub token are required before pulling.", true)
		return
	_busy = true
	var author_name = _github_username if _github_username != "" else _fallback_username()
	var init_result = _git.init_repository(project_path)
	if init_result.get("code", 0) != 0:
		_busy = false
		_set_status(_join_lines(init_result.get("output", ["Git init failed"])) , true)
		return
	_git.ensure_remote(project_path, "origin", _current_repo_url)
	var result = _git.pull(project_path, _current_repo_url, "main", author_name, _github_token)
	_busy = false
	if result.get("code", 0) == 0:
		_set_status("Latest changes pulled from GitHub.")
		_refresh_project_files()
	else:
		_set_status(_join_lines(result.get("output", ["Git pull failed"])) , true)

func _refresh_project_files():
	if _editor_interface:
		_editor_interface.get_resource_filesystem().scan()
	_set_status("Project files refreshed.")

func _open_repository():
	if _current_repo_url == "":
		_set_status("No repository URL available yet.", true)
		return
	OS.shell_open(_current_repo_url)

func _project_root():
	if _project_path != "":
		return _project_path
	return ProjectSettings.globalize_path("res://")

func _fallback_username():
	if _user_email.find("@") != -1:
		return _user_email.split("@")[0]
	return "User"

func _join_lines(lines):
	if typeof(lines) == TYPE_ARRAY:
		return "\n".join(lines)
	return str(lines)

func _save_state():
	var cfg = ConfigFile.new()
	cfg.set_value("grtc", "server_url", _server_url)
	cfg.set_value("grtc", "user_email", _user_email)
	cfg.set_value("grtc", "session_id", _session_id)
	cfg.set_value("grtc", "user_id", _user_id)
	cfg.set_value("grtc", "github_username", _github_username)
	cfg.set_value("grtc", "project_path", _project_path)
	cfg.set_value("grtc", "current_repo_url", _current_repo_url)
	cfg.set_value("grtc", "github_token", _github_token)
	cfg.save("user://grtc_panel.cfg")

func _load_state():
	var cfg = ConfigFile.new()
	if cfg.load("user://grtc_panel.cfg") != OK:
		_project_path = ProjectSettings.globalize_path("res://")
		return
	_server_url = str(cfg.get_value("grtc", "server_url", SERVER_DEFAULT))
	_user_email = str(cfg.get_value("grtc", "user_email", ""))
	_session_id = str(cfg.get_value("grtc", "session_id", ""))
	_user_id = str(cfg.get_value("grtc", "user_id", ""))
	_github_username = str(cfg.get_value("grtc", "github_username", ""))
	_project_path = str(cfg.get_value("grtc", "project_path", ProjectSettings.globalize_path("res://")))
	_current_repo_url = str(cfg.get_value("grtc", "current_repo_url", ""))
	_github_token = str(cfg.get_value("grtc", "github_token", ""))
