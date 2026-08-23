tool
extends VBoxContainer

const SERVER_DEFAULT = "http://localhost:8000"

var _http = null
var _auth_http = null
var _git = preload("res://addons/grtc/grtc_git_helper.gd").new()
var _editor_interface = null

var _busy = false
var _auth_polling = false
var _auth_request_in_flight = false
var _auth_request_mode = ""
var _auth_poll_started_at = 0
var _auth_last_poll_at = 0
var _auth_poll_interval_ms = 1500
var _auth_timeout_ms = 120000
var _login_state = ""

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

func set_editor_interface(editor_interface):
	_editor_interface = editor_interface

func _ready():
	_auth_http = HTTPRequest.new()
	add_child(_auth_http)
	_auth_http.connect("request_completed", self, "_on_auth_request_completed")
	_build_ui()
	_load_state()
	_refresh_fields()
	_restore_saved_session()
	_set_status("Ready")
	set_process(true)

func _exit_tree():
	_auth_polling = false
	_save_state()

func _process(delta):
	if not _auth_polling or _auth_request_in_flight:
		return
	var now = OS.get_ticks_msec()
	if now - _auth_poll_started_at > _auth_timeout_ms:
		_auth_polling = false
		_set_status("Login timed out. Open GitHub login again.", true)
		return
	if now - _auth_last_poll_at < _auth_poll_interval_ms:
		return
	_poll_latest_auth()

func _restore_saved_session():
	if _session_id == "":
		return
	_auth_request_mode = "session"
	var headers = PoolStringArray(["X-Session-ID: %s" % _session_id])
	_auth_request_in_flight = true
	_auth_last_poll_at = OS.get_ticks_msec()
	var err = _auth_http.request(_server_url + "/github/session-auth", headers)
	if err != OK:
		_auth_request_in_flight = false
		_set_status("Failed to restore saved session (%s)." % str(err), true)

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
	print("[GRTC] Email changed: '", _user_email, "'")
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

func _on_login_pressed():
	print("[GRTC] Login button pressed, email: '", _user_email, "'")
	if _user_email == "":
		_set_status("Your Email is required before login.", true)
		return
	_login_state = _generate_login_state()
	var url = _server_url + "/github/login?state=" + _encode_query(_login_state)
	print("[GRTC] Opening URL: ", url)
	var err = OS.shell_open(url)
	if err != OK:
		_set_status("Failed to open browser: " + str(err), true)
		print("[GRTC] shell_open error: ", err)
	else:
		_auth_request_mode = "login"
		_auth_polling = true
		_auth_poll_started_at = OS.get_ticks_msec()
		_auth_last_poll_at = 0
		_set_status("Opened GitHub login in your browser.")

func _poll_latest_auth():
	if _auth_http == null or _login_state == "":
		return
	_auth_request_in_flight = true
	_auth_last_poll_at = OS.get_ticks_msec()
	var url = _server_url + "/github/latest-auth?state=" + _encode_query(_login_state)
	var err = _auth_http.request(url)
	if err != OK:
		_auth_request_in_flight = false
		_set_status("Failed to poll login state (%s)." % str(err), true)

func _on_auth_request_completed(result, response_code, headers, body):
	_auth_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS:
		_set_status("Login poll failed (network error).", true)
		_auth_polling = false
		return

	if response_code == 404:
		# Login not completed yet, keep polling
		_set_status("Waiting for GitHub login to complete...")
		return

	if response_code != 200:
		_set_status("Login poll error: HTTP %d" % response_code, true)
		_auth_polling = false
		return

	var parsed = JSON.parse(body.get_string_from_utf8())
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		_set_status("Invalid response from server.", true)
		_auth_polling = false
		return

	var data = parsed.result
	if not data.get("success", false):
		_set_status("Login failed: %s" % str(data.get("message", "Unknown error")), true)
		_auth_polling = false
		return

	_session_id = str(data.get("session_id", _session_id))
	_user_id = str(data.get("user", {}).get("id", _user_id))
	_github_username = str(data.get("user", {}).get("username", _github_username))
	_user_email = str(data.get("user", {}).get("email", _user_email))
	_github_token = str(data.get("github_token", _github_token))
	_current_repo_url = _resolve_repo_url()
	_auth_polling = false
	_login_state = ""
	_refresh_fields()
	_save_state()
	_set_status("Login synced. Session restored and token loaded in memory.")

func _on_push_pressed():
	if _busy:
		return
	var project_path = _project_root()
	if project_path == "":
		_set_status("Project path is required.", true)
		return
	if _current_repo_url == "":
		_current_repo_url = _resolve_repo_url()
	if _current_repo_url == "" or _github_token == "":
		_set_status("Repository URL or GitHub session is missing. Login again if needed.", true)
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
	if _current_repo_url == "":
		_current_repo_url = _resolve_repo_url()
	if _current_repo_url == "" or _github_token == "":
		_set_status("Repository URL or GitHub session is missing. Login again if needed.", true)
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
	_current_repo_url = _resolve_repo_url()
	_refresh_fields()
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

func _resolve_repo_url():
	var project_path = _project_root()
	if project_path == "":
		return _current_repo_url
	var remote_url = _git.get_remote_url(project_path, "origin")
	if remote_url != "":
		return remote_url
	return _current_repo_url

func _encode_query(value):
	var out = ""
	for i in range(value.length()):
		var c = value[i]
		if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95 or c == 46 or c == 126:
			out += char(c)
		else:
			out += "%%%02X" % c
	return out

func _generate_login_state():
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return str(OS.get_unix_time()) + "_" + str(rng.randi())

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
	_github_token = ""
