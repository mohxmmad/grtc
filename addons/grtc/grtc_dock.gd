tool
extends VBoxContainer

const SERVER_DEFAULT = "http://localhost:8000"
const PROJECT_SCAN_INTERVAL_MS = 2000

var _http = null
var _auth_http = null
var _git = preload("res://addons/grtc/grtc_git_helper.gd").new()
var _editor_interface = null
var _ws = null

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
var _collaboration_room = ""
var _project_snapshot = {}
var _last_project_scan_at = 0
var _ws_connected = false
var _ws_connecting = false
var _client_instance_id = ""
var _auto_apply_remote_changes = true
var _pending_remote_changes = []
var _remote_event_log = []

var _status_label = null
var _server_edit = null
var _email_edit = null
var _session_edit = null
var _user_id_edit = null
var _username_edit = null
var _project_path_edit = null
var _repo_url_edit = null
var _collaboration_room_edit = null
var _auto_apply_check = null
var _remote_changes_list = null
var _pending_count_label = null

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
	_refresh_collaboration_room()
	_client_instance_id = _generate_client_instance_id()
	_project_snapshot = _scan_project_snapshot()
	_set_status("Ready")
	set_process(true)

func _exit_tree():
	_auth_polling = false
	_disconnect_collaboration()
	_save_state()

func _process(delta):
	if _auth_polling and not _auth_request_in_flight:
		var now = OS.get_ticks_msec()
		if now - _auth_poll_started_at > _auth_timeout_ms:
			_auth_polling = false
			_set_status("Login timed out. Open GitHub login again.", true)
		elif now - _auth_last_poll_at >= _auth_poll_interval_ms:
			_poll_latest_auth()
	_poll_websocket()
	_poll_project_changes()

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
	help.text = "Godot editor-side GRTC panel. Login opens the backend OAuth page; Git push/pull runs locally from the current project folder; collaboration uses the websocket room for the active project."
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
	parent_add(_row_line_edit("Collab Room", false, _collaboration_room, self, ""), self)
	_collaboration_room_edit = get_child(get_child_count() - 1).get_child(1)

	var remote_panel = VBoxContainer.new()
	remote_panel.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(remote_panel)

	var remote_title = Label.new()
	remote_title.text = "Remote Collaboration"
	remote_panel.add_child(remote_title)

	_auto_apply_check = CheckBox.new()
	_auto_apply_check.text = "Auto Apply Remote Changes"
	_auto_apply_check.set_pressed_no_signal(_auto_apply_remote_changes)
	_auto_apply_check.connect("toggled", self, "_on_auto_apply_toggled")
	remote_panel.add_child(_auto_apply_check)

	_pending_count_label = Label.new()
	_pending_count_label.text = "Pending changes: 0"
	remote_panel.add_child(_pending_count_label)

	var remote_actions = HBoxContainer.new()
	remote_panel.add_child(remote_actions)
	_add_button(remote_actions, "Apply Pending", self, "_apply_pending_remote_changes")
	_add_button(remote_actions, "Clear Queue", self, "_clear_pending_remote_changes")

	_remote_changes_list = ItemList.new()
	_remote_changes_list.rect_min_size = Vector2(0, 120)
	_remote_changes_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_remote_changes_list.size_flags_vertical = SIZE_EXPAND_FILL
	remote_panel.add_child(_remote_changes_list)

	var actions = HBoxContainer.new()
	add_child(actions)
	_add_button(actions, "Login with GitHub", self, "_on_login_pressed")
	_add_button(actions, "Connect Collaboration", self, "_on_connect_collaboration_pressed")
	_add_button(actions, "Disconnect Collaboration", self, "_on_disconnect_collaboration_pressed")
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
	_set_line_edit(_collaboration_room_edit, _collaboration_room)
	if _auto_apply_check:
		_auto_apply_check.set_pressed_no_signal(_auto_apply_remote_changes)
	_refresh_pending_remote_ui()

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
	_refresh_collaboration_room()
	_save_state()

func _on_repo_url_changed(text):
	_current_repo_url = text.strip_edges()
	_refresh_collaboration_room()
	_save_state()

func _on_auto_apply_toggled(button_pressed):
	_auto_apply_remote_changes = button_pressed
	_save_state()
	_set_status("Auto apply %s." % ("enabled" if _auto_apply_remote_changes else "disabled"))

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
		_scan_and_broadcast_changes(true)
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

func _on_connect_collaboration_pressed():
	if _ws_connected or _ws_connecting:
		_set_status("Collaboration is already connected.")
		return
	if _session_id == "":
		_set_status("Session ID is required. Log in first.", true)
		return
	_refresh_collaboration_room()
	if _collaboration_room == "":
		_set_status("Unable to derive a collaboration room.", true)
		return
	var ws_url = _collaboration_ws_url()
	_ws = WebSocketClient.new()
	var err = _ws.connect("connection_established", self, "_on_ws_connection_established")
	if err != OK:
		_set_status("Failed to bind websocket connection signal.", true)
		return
	_ws.connect("connection_error", self, "_on_ws_connection_error")
	_ws.connect("connection_closed", self, "_on_ws_connection_closed")
	_ws.connect("data_received", self, "_on_ws_data_received")
	err = _ws.connect_to_url(ws_url)
	if err != OK:
		_ws = null
		_set_status("Failed to connect websocket: %s" % str(err), true)
		return
	_ws_connecting = true
	_set_status("Connecting collaboration socket...")

func _on_disconnect_collaboration_pressed():
	_disconnect_collaboration()
	_set_status("Collaboration disconnected.")

func _disconnect_collaboration():
	_ws_connecting = false
	_ws_connected = false
	if _ws:
		if _ws.get_connection_status() != WebSocketClient.CONNECTION_DISCONNECTED:
			_ws.disconnect_from_host(1000, "client disconnect")
		_ws = null

func _poll_websocket():
	if _ws == null:
		return
	_ws.poll()
	var status = _ws.get_connection_status()
	if status == WebSocketClient.CONNECTION_CONNECTING:
		return
	if status == WebSocketClient.CONNECTION_CONNECTED:
		return
	if _ws_connected or _ws_connecting:
		_ws_connected = false
		_ws_connecting = false
		_set_status("Collaboration socket closed.", true)

func _on_ws_connection_established(protocol = ""):
	_ws_connected = true
	_ws_connecting = false
	_set_status("Collaboration connected to %s." % _collaboration_room)
	_send_ws_json({"type": "join", "room": _collaboration_room})
	_send_ws_json({"type": "sync_request"})
	_project_snapshot = _scan_project_snapshot()

func _on_ws_connection_error():
	_ws_connected = false
	_ws_connecting = false
	_set_status("Collaboration connection failed.", true)

func _on_ws_connection_closed(was_clean = false):
	_ws_connected = false
	_ws_connecting = false
	_set_status("Collaboration connection closed.", true)

func _on_ws_data_received():
	if _ws == null or not _ws_connected:
		return
	var peer = _ws.get_peer(1)
	if peer == null:
		return
	while peer.get_available_packet_count() > 0:
		var packet = peer.get_packet()
		var parsed = JSON.parse(packet.get_string_from_utf8())
		if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
			continue
		_handle_ws_message(parsed.result)

func _handle_ws_message(message):
	var message_type = str(message.get("type", ""))
	if message_type == "event":
		_handle_remote_event(message)
	elif message_type == "sync_state":
		print("[GRTC][WS] Sync state: ", message)
	elif message_type == "error":
		_set_status(str(message.get("message", "Websocket error")), true)

func _handle_remote_event(message):
	var data = message.get("data", {})
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var source_id = str(data.get("source_client_id", message.get("client_id", "")))
	if source_id != "" and source_id == _client_instance_id:
		return
	var change = {
		"type": str(message.get("event", "file_updated")),
		"timestamp": str(message.get("timestamp", "")),
		"path": str(data.get("path", data.get("file_path", ""))),
		"project_room": str(message.get("room", _collaboration_room)),
		"data": data,
		"source_client_id": source_id
	}
	_queue_or_apply_remote_change(change)

func _queue_or_apply_remote_change(change):
	_append_remote_log(change)
	if _auto_apply_remote_changes:
		_apply_remote_change(change)
		return
	_pending_remote_changes.append(change)
	_refresh_pending_remote_ui()
	_set_status("Queued remote change for %s." % str(change.get("path", "unknown file")))

func _append_remote_log(change):
	_remote_event_log.append(change)
	if _remote_event_log.size() > 25:
		_remote_event_log.remove(0)
	_refresh_remote_log_ui()

func _refresh_remote_log_ui():
	if _remote_changes_list == null:
		return
	_remote_changes_list.clear()
	for change in _remote_event_log:
		var label = "%s | %s" % [str(change.get("type", "event")), str(change.get("path", "unknown"))]
		_remote_changes_list.add_item(label)

func _refresh_pending_remote_ui():
	if _pending_count_label:
		_pending_count_label.text = "Pending changes: %d" % _pending_remote_changes.size()

func _clear_pending_remote_changes():
	_pending_remote_changes.clear()
	_refresh_pending_remote_ui()
	_set_status("Pending remote changes cleared.")

func _apply_pending_remote_changes():
	if _pending_remote_changes.size() == 0:
		_set_status("No pending remote changes.")
		return
	for change in _pending_remote_changes:
		_apply_remote_change(change)
	_pending_remote_changes.clear()
	_refresh_pending_remote_ui()
	_set_status("Applied pending remote changes.")

func _apply_remote_change(change):
	var event_type = str(change.get("type", "file_updated"))
	var data = change.get("data", {})
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var relative_path = str(data.get("path", change.get("path", "")))
	if relative_path == "":
		return
	var local_path = _resolve_project_file_path(relative_path)
	if local_path == "":
		return

	var applied = false
	if event_type == "file_deleted" or event_type == "deleted":
		applied = _delete_local_file(local_path)
	else:
		var file_content = str(data.get("file_content", ""))
		var encoding = str(data.get("file_encoding", "base64"))
		var raw_bytes = PoolByteArray()
		if encoding == "base64" and file_content != "":
			raw_bytes = Marshalls.base64_to_raw(file_content)
		elif file_content != "":
			raw_bytes = file_content.to_utf8()
		applied = _write_local_file(local_path, raw_bytes)

	if applied:
		_project_snapshot = _scan_project_snapshot()
		_refresh_fields()
		if _editor_interface:
			_editor_interface.get_resource_filesystem().scan()
		_set_status("Applied remote %s: %s" % [event_type, relative_path])

func _resolve_project_file_path(relative_path):
	var path = relative_path.strip_edges()
	if path == "":
		return ""
	if path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	if path.find("://") != -1:
		return ""
	if path.begins_with("/"):
		return path
	return _project_root().plus_file(path)

func _write_local_file(path, bytes):
	var dir = Directory.new()
	var folder = path.get_base_dir()
	if folder != "" and not dir.dir_exists(folder):
		if dir.make_dir_recursive(folder) != OK:
			return false
	var file = File.new()
	if file.open(path, File.WRITE) != OK:
		return false
	if bytes.size() > 0:
		file.store_buffer(bytes)
	file.close()
	return true

func _delete_local_file(path):
	var dir = Directory.new()
	if not dir.file_exists(path):
		return true
	return dir.remove(path) == OK

func _send_ws_json(payload):
	if _ws == null or not _ws_connected:
		return
	var peer = _ws.get_peer(1)
	if peer == null:
		return
	peer.put_packet(to_json(payload).to_utf8())

func _poll_project_changes():
	if not _ws_connected:
		return
	var now = OS.get_ticks_msec()
	if now - _last_project_scan_at < PROJECT_SCAN_INTERVAL_MS:
		return
	_last_project_scan_at = now
	_scan_and_broadcast_changes(false)

func _scan_and_broadcast_changes(force):
	var current_snapshot = _scan_project_snapshot()
	var changes = _diff_snapshots(_project_snapshot, current_snapshot)
	if changes.size() == 0:
		return
	_project_snapshot = current_snapshot
	if not _ws_connected and not force:
		return
	for change in changes:
		_broadcast_file_change(change)
	_set_status("Broadcasted %d project change(s)." % changes.size())

func _broadcast_file_change(change):
	var path = str(change.get("path", ""))
	if path == "":
		return
	var relative_path = _to_project_relative_path(path)
	var event_type = str(change.get("kind", "modified"))
	if event_type == "created":
		event_type = "file_created"
	elif event_type == "deleted":
		event_type = "file_deleted"
	else:
		event_type = "file_updated"
	var data = {
		"path": relative_path,
		"project_room": _collaboration_room,
		"project_path": _project_path,
		"repo_url": _current_repo_url,
		"kind": event_type,
		"source_client_id": _client_instance_id
	}
	if event_type != "file_deleted":
		data["file_content"] = _read_file_as_base64(path)
		data["file_encoding"] = "base64"
	_send_ws_json({
		"type": "publish",
		"room": _collaboration_room,
		"event": event_type,
		"data": data
	})

func _scan_project_snapshot():
	var snapshot = {}
	var root_path = _project_root()
	if root_path == "":
		return snapshot
	_scan_directory_recursive(root_path, snapshot)
	return snapshot

func _scan_directory_recursive(path, snapshot):
	var dir = Directory.new()
	if dir.open(path) != OK:
		return
	dir.list_dir_begin(true, true)
	while true:
		var name = dir.get_next()
		if name == "":
			break
		if _is_ignored_entry(path, name, dir.current_is_dir()):
			continue
		var full_path = path.plus_file(name)
		if dir.current_is_dir():
			_scan_directory_recursive(full_path, snapshot)
		else:
			var file = File.new()
			snapshot[full_path] = str(file.get_modified_time(full_path))
	dir.list_dir_end()

func _is_ignored_entry(path, name, is_dir):
	if name == "." or name == "..":
		return true
	if name.begins_with(".") and is_dir:
		return true
	if name == ".import" or name == ".git" or name == ".godot" or name == ".mono":
		return true
	return false

func _diff_snapshots(old_snapshot, new_snapshot):
	var changes = []
	for path in new_snapshot.keys():
		if not old_snapshot.has(path):
			changes.append({"kind": "created", "path": path})
		elif str(old_snapshot[path]) != str(new_snapshot[path]):
			changes.append({"kind": "modified", "path": path})
	for path in old_snapshot.keys():
		if not new_snapshot.has(path):
			changes.append({"kind": "deleted", "path": path})
	return changes

func _read_file_as_base64(path):
	var file = File.new()
	if file.open(path, File.READ) != OK:
		return ""
	var bytes = file.get_buffer(file.get_len())
	file.close()
	return Marshalls.raw_to_base64(bytes)

func _to_project_relative_path(path):
	var root_path = _project_root()
	if root_path != "" and path.begins_with(root_path):
		var rel = path.substr(root_path.length(), path.length() - root_path.length())
		if rel.begins_with("/"):
			rel = rel.substr(1, rel.length() - 1)
		return rel
	return path

func _refresh_collaboration_room():
	var room_seed = _current_repo_url
	if room_seed == "":
		room_seed = _project_root()
	if room_seed == "":
		_collaboration_room = ""
	else:
		_collaboration_room = "project:" + room_seed.md5_text()
	_set_line_edit(_collaboration_room_edit, _collaboration_room)

func _generate_client_instance_id():
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return str(OS.get_unix_time()) + "_" + str(rng.randi())

func _collaboration_ws_url():
	var base = _server_url.strip_edges()
	if base.begins_with("https://"):
		base = "wss://" + base.substr(8, base.length() - 8)
	elif base.begins_with("http://"):
		base = "ws://" + base.substr(7, base.length() - 7)
	elif not base.begins_with("ws://") and not base.begins_with("wss://"):
		base = "ws://" + base
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	return base + "/ws?session_id=" + _encode_query(_session_id) + "&client=godot&room=" + _encode_query(_collaboration_room)

func _encode_query(value):
	var out = ""
	for i in range(value.length()):
		var c = value[i]
		var ord_c = ord(c)
		if (ord_c >= 48 and ord_c <= 57) or (ord_c >= 65 and ord_c <= 90) or (ord_c >= 97 and ord_c <= 122) or ord_c == 45 or ord_c == 95 or ord_c == 46 or ord_c == 126:
			out += char(ord_c)
		else:
			out += "%%%02X" % ord_c
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
	cfg.set_value("grtc", "auto_apply_remote_changes", _auto_apply_remote_changes)
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
	_auto_apply_remote_changes = bool(cfg.get_value("grtc", "auto_apply_remote_changes", true))
	_github_token = ""
