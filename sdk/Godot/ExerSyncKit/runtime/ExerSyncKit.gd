class_name ExerSyncKit
extends Object

enum ControllerServerState {
	STOPPED,
	STARTING,
	RUNNING,
	STOPPING,
	COOLDOWN,
}

const DEFAULT_BUTTON_MASKS := {
	"UP": 1 << 0,
	"DOWN": 1 << 1,
	"LEFT": 1 << 2,
	"RIGHT": 1 << 3,
	"START": 1 << 4,
	"BACK": 1 << 5,
	"LS": 1 << 6,
	"RS": 1 << 7,
	"LB": 1 << 8,
	"RB": 1 << 9,
	"LT": 1 << 10,
	"RT": 1 << 11,
	"A": 1 << 12,
	"B": 1 << 13,
	"X": 1 << 14,
	"Y": 1 << 15,
}

const DEFAULT_WS_URL := "ws://127.0.0.1:38421/controller"
const DEFAULT_SERVER_EXE_NAME := "ExerSyncKitServer.exe"
const MIN_RESTART_DELAY_MS := 5000
const POST_LAUNCH_CONNECT_DELAY_MS := 500
const CHUNK_SIZE := 400
const MAX_INLINE_LAYOUT_UTF8_BYTES := 480
const MAIN_THREAD_PUMP_AUTOLOAD := "/root/ExerSyncKitMainThreadPump"


class InputState:
	var player_id: int = -1
	var joy_lx: float = 0.0
	var joy_ly: float = 0.0
	var joy_rx: float = 0.0
	var joy_ry: float = 0.0
	var buttons: int = 0

	static func from_dict(data: Dictionary) -> InputState:
		var state := InputState.new()
		state.player_id = int(data.get("playerId", data.get("PlayerId", -1)))
		state.joy_lx = float(data.get("joyLX", data.get("JoyLX", 0.0)))
		state.joy_ly = float(data.get("joyLY", data.get("JoyLY", 0.0)))
		state.joy_rx = float(data.get("joyRX", data.get("JoyRX", 0.0)))
		state.joy_ry = float(data.get("joyRY", data.get("JoyRY", 0.0)))
		state.buttons = int(data.get("buttons", data.get("Buttons", 0)))
		return state


class GeotagImageExportResult:
	var success: bool = false
	var export_path: String = ""
	var error: String = ""


signal StateChanged(state: ControllerServerState, remaining_cooldown_ms: int)
signal Cooldown(remaining_ms: int)
signal OnConnected
signal OnDisconnected
signal OnControllerConnected(player_id: int)
signal OnControllerDisconnected(player_id: int)
signal OnPause
signal OnResume
signal OnInput(player_id: int, state: InputState)
signal Error(err: Variant)
signal ServerUnavailable(reason: String)

var server_exe_name: String = DEFAULT_SERVER_EXE_NAME
var server_exe_directory: String = ""
var connected_controllers: Array[int] = []

static var _cooldown_until_ms: int = 0

var _bound_on_state_changed: Callable
var _bound_on_connected: Callable
var _bound_on_disconnected: Callable
var _bound_on_server_unavailable: Callable
var _bound_on_controller_connected: Callable
var _bound_on_controller_disconnected: Callable
var _bound_on_pause: Callable
var _bound_on_resume: Callable
var _bound_on_input: Callable

var _server_exe_path: String = ""
var _socket: WebSocketPeer
var _line_queue: Array[String] = []
var _buffer: String = ""
var _game_id: String = ""
var _version: int = 1
var _layout_json: Variant = null
var _url: String = DEFAULT_WS_URL

var _server_started: bool = false
var _process_launch_ok: bool = false
var _is_manual_disconnect: bool = false
var _suppress_connection_loss_notifications: bool = false
var _connect_generation: int = 0
var _is_sending_large_data: bool = false
var _current_transfer_id: int = 0
var _server_pid: int = -1

var _pending_step_request_id: String = ""
var _pending_step_promise: Array = []
var _pending_geotag_request_id: String = ""
var _pending_geotag_promise: Array = []

var _lifecycle: ControllerServerState = ControllerServerState.STOPPED
var _reconnect_timer: SceneTreeTimer
var _connect_delay_timer: SceneTreeTimer
var _cooldown_timer: SceneTreeTimer
var _socket_open: bool = false
var _is_connecting: bool = false


func _init() -> void:
	_register_with_main_thread_pump()


func get_state() -> ControllerServerState:
	return _lifecycle


func get_remaining_cooldown_ms() -> int:
	return maxi(0, _cooldown_until_ms - Time.get_ticks_msec())


func get_controller_count() -> int:
	return connected_controllers.size()


func is_in_cooldown() -> bool:
	return get_controller_count() > 0


func is_player_connected(player_id: int) -> bool:
	return connected_controllers.has(player_id)


func enable_async(options: ExerSyncKitEnableOptions) -> bool:
	if options == null:
		push_error("[PhoneController] enable_async: options is required.")
		return false
	if options.GameId.is_empty():
		push_error("[PhoneController] enable_async: GameId is required.")
		return false

	bind_options_callbacks(options)

	if _lifecycle == ControllerServerState.RUNNING \
			or _lifecycle == ControllerServerState.STARTING:
		return true

	if not launch_server():
		var cooldown_ms := get_remaining_cooldown_ms()
		if cooldown_ms > 0:
			Cooldown.emit(cooldown_ms)
		return false

	var version := options.Version if options.Version > 0 else 1
	await connect_to_controller_async(options.GameId, version, options.LayoutJson)
	return true


func bind_options_callbacks(options: ExerSyncKitEnableOptions) -> void:
	unbind_options_callbacks()
	if options.OnStateChanged.is_valid():
		_bound_on_state_changed = options.OnStateChanged
		StateChanged.connect(_bound_on_state_changed)
	if options.OnConnected.is_valid():
		_bound_on_connected = options.OnConnected
		OnConnected.connect(_bound_on_connected)
	if options.OnDisconnected.is_valid():
		_bound_on_disconnected = options.OnDisconnected
		OnDisconnected.connect(_bound_on_disconnected)
	if options.OnControllerConnected.is_valid():
		_bound_on_controller_connected = options.OnControllerConnected
		OnControllerConnected.connect(_bound_on_controller_connected)
	if options.OnControllerDisconnected.is_valid():
		_bound_on_controller_disconnected = options.OnControllerDisconnected
		OnControllerDisconnected.connect(_bound_on_controller_disconnected)
	if options.OnPause.is_valid():
		_bound_on_pause = options.OnPause
		OnPause.connect(_bound_on_pause)
	if options.OnResume.is_valid():
		_bound_on_resume = options.OnResume
		OnResume.connect(_bound_on_resume)
	if options.OnServerUnavailable.is_valid():
		_bound_on_server_unavailable = options.OnServerUnavailable
		ServerUnavailable.connect(_bound_on_server_unavailable)
	if options.OnInput.is_valid():
		_bound_on_input = options.OnInput
		OnInput.connect(_bound_on_input)


func unbind_options_callbacks() -> void:
	if _bound_on_state_changed.is_valid():
		if StateChanged.is_connected(_bound_on_state_changed):
			StateChanged.disconnect(_bound_on_state_changed)
		_bound_on_state_changed = Callable()
	if _bound_on_connected.is_valid():
		if OnConnected.is_connected(_bound_on_connected):
			OnConnected.disconnect(_bound_on_connected)
		_bound_on_connected = Callable()
	if _bound_on_disconnected.is_valid():
		if OnDisconnected.is_connected(_bound_on_disconnected):
			OnDisconnected.disconnect(_bound_on_disconnected)
		_bound_on_disconnected = Callable()
	if _bound_on_controller_connected.is_valid():
		if OnControllerConnected.is_connected(_bound_on_controller_connected):
			OnControllerConnected.disconnect(_bound_on_controller_connected)
		_bound_on_controller_connected = Callable()
	if _bound_on_controller_disconnected.is_valid():
		if OnControllerDisconnected.is_connected(_bound_on_controller_disconnected):
			OnControllerDisconnected.disconnect(_bound_on_controller_disconnected)
		_bound_on_controller_disconnected = Callable()
	if _bound_on_pause.is_valid():
		if OnPause.is_connected(_bound_on_pause):
			OnPause.disconnect(_bound_on_pause)
		_bound_on_pause = Callable()
	if _bound_on_resume.is_valid():
		if OnResume.is_connected(_bound_on_resume):
			OnResume.disconnect(_bound_on_resume)
		_bound_on_resume = Callable()
	if _bound_on_server_unavailable.is_valid():
		if ServerUnavailable.is_connected(_bound_on_server_unavailable):
			ServerUnavailable.disconnect(_bound_on_server_unavailable)
		_bound_on_server_unavailable = Callable()
	if _bound_on_input.is_valid():
		if OnInput.is_connected(_bound_on_input):
			OnInput.disconnect(_bound_on_input)
		_bound_on_input = Callable()


func launch_server() -> bool:
	if _lifecycle == ControllerServerState.STARTING \
			or _lifecycle == ControllerServerState.RUNNING:
		return true
	if _lifecycle == ControllerServerState.STOPPING:
		return false

	var cooldown_ms := get_remaining_cooldown_ms()
	if cooldown_ms > 0:
		_emit_cooldown(cooldown_ms)
		_set_state(ControllerServerState.COOLDOWN, cooldown_ms)
		_process_launch_ok = false
		return false

	_set_state(ControllerServerState.STARTING)

	if OS.get_name() != "Windows":
		push_warning("[PhoneController] LaunchServer: only supported on Windows.")
		_process_launch_ok = false
		_set_state(ControllerServerState.STOPPED)
		return false

	var resolved := _resolve_server_exe()
	if resolved.is_empty():
		push_error(
			"[PhoneController] Missing %s. Build pc-server/Server.Ble and copy ExerSyncKitServer.exe to:\n"
			% server_exe_name
			+ "  • next to your game .exe (builds), or\n"
			+ "  • addons/ExerSyncKit/server/ (Editor), or\n"
			+ "  • set server_exe_directory on ExerSyncKit."
		)
		_process_launch_ok = false
		_set_state(ControllerServerState.STOPPED)
		return false

	var exe_path: String = resolved.path
	_server_exe_path = exe_path
	var args := PackedStringArray([str(OS.get_process_id()), "--no-activate"])
	_server_pid = OS.create_process(exe_path, args, false)
	if _server_pid <= 0:
		push_error("[PhoneController] Server process did not start.")
		_process_launch_ok = false
		_set_state(ControllerServerState.STOPPED)
		return false

	print("[PhoneController] Launched server: %s (pid %d)" % [exe_path, _server_pid])
	_process_launch_ok = true
	_set_state(ControllerServerState.RUNNING)
	return true


func connect_to_controller(
	game_id: String,
	version: int = 1,
	layout_json: Variant = null,
	url: String = DEFAULT_WS_URL
) -> void:
	connect_to_controller_async(game_id, version, layout_json, url)


func connect_to_controller_async(
	game_id: String,
	version: int = 1,
	layout_json: Variant = null,
	url: String = DEFAULT_WS_URL
) -> void:
	if _lifecycle == ControllerServerState.STOPPING \
			or _lifecycle == ControllerServerState.COOLDOWN:
		push_warning(
			"[PhoneController] ConnectAsync blocked: state is %s."
			% _state_name(_lifecycle)
		)
		return

	_game_id = game_id
	_version = version
	_layout_json = layout_json
	if not url.is_empty():
		_url = url
	_is_manual_disconnect = false
	_suppress_connection_loss_notifications = false
	_register_with_main_thread_pump()

	var cooldown_ms := get_remaining_cooldown_ms()
	if cooldown_ms > 0:
		_emit_cooldown(cooldown_ms)
		_set_state(ControllerServerState.COOLDOWN, cooldown_ms)
		return

	_cancel_reconnect_timer()
	_cancel_connect_delay_timer()
	_connect_generation += 1
	var generation := _connect_generation

	var delay_ms := POST_LAUNCH_CONNECT_DELAY_MS if _process_launch_ok else 0
	var tree := _get_tree()
	if tree == null:
		push_error("[PhoneController] SceneTree not ready for WebSocket connection.")
		return
	if delay_ms > 0:
		_connect_delay_timer = tree.create_timer(delay_ms / 1000.0)
		_connect_delay_timer.timeout.connect(func() -> void:
			if generation == _connect_generation:
				_establish_connection()
		, CONNECT_ONE_SHOT)
	else:
		_establish_connection()


func poll_socket() -> void:
	if _socket == null:
		return

	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_is_connecting = false
			_on_websocket_opened()
			_drain_incoming_packets()
		WebSocketPeer.STATE_CONNECTING:
			pass
		WebSocketPeer.STATE_CLOSED, WebSocketPeer.STATE_CLOSING:
			var was_open := _socket_open
			var was_connecting := _is_connecting
			_is_connecting = false
			if was_open:
				_handle_socket_closed()
			elif was_connecting:
				push_warning(
					"[PhoneController] WebSocket closed before open (code=%d, reason=%s)."
					% [_socket.get_close_code(), _socket.get_close_reason()]
				)
				_teardown_socket()
				if _is_server_still_running():
					_schedule_reconnect()
				else:
					_notify_server_unavailable("Server process is not running.")


func process_pending_lines() -> void:
	while _line_queue.size() > 0:
		var line: String = _line_queue.pop_front()
		if line == "__CLOSED__":
			if _should_report_connection_loss():
				_handle_socket_closed()
		else:
			_process_one_line(line)


func send_command(player_id: int, command: String) -> void:
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	var payload: String
	if player_id == -2:
		payload = "SYSTEM:%s" % command
	else:
		payload = "TARGET:%d:%s" % [player_id, command]

	var err := _socket.send_text(payload)
	if err != OK:
		push_warning("[PhoneController] send_text failed (%d): %s" % [err, payload])
		return
	# Godot requires poll() to flush outbound WebSocket frames.
	_socket.poll()


func broadcast_command(command: String) -> void:
	send_command(-1, command)


func get_step_counter_async(player_id: int = -1, timeout_ms: int = 3000) -> int:
	if not _pending_step_promise.is_empty():
		return -1

	var req_id := _random_request_id()
	_pending_step_request_id = req_id
	_pending_step_promise = [-1]
	send_command(player_id, "GET_STEP_COUNT:%s" % req_id)

	var tree := _get_tree()
	if tree == null:
		_pending_step_promise.clear()
		_pending_step_request_id = ""
		return -1

	var timer := tree.create_timer(timeout_ms / 1000.0)
	while _pending_step_promise.size() > 0:
		await tree.process_frame
		if timer.time_left <= 0.0:
			break

	var result := -1
	if _pending_step_promise.size() > 0:
		result = int(_pending_step_promise[0])
	_pending_step_promise.clear()
	_pending_step_request_id = ""
	return result


func enable_step(player_id: int = -1) -> void:
	send_command(player_id, "ENABLE_STEP")


func enable_steering(player_id: int = -1) -> void:
	send_command(player_id, "ENABLE_STEERING")


func disable_steering(player_id: int = -1) -> void:
	send_command(player_id, "DISABLE_STEERING")


func disable_step(player_id: int = -1) -> void:
	send_command(player_id, "DISABLE_STEP")


func reset_step_counter(player_id: int = -1) -> void:
	send_command(player_id, "RESET_STEP_COUNT")


func trigger_vibration(player_id: int = -1) -> void:
	send_command(player_id, "VIBRATE")


func export_geotagged_image_async(
	latitude: float,
	longitude: float,
	export_path: String,
	source_image_path: String,
	timeout_ms: int = 15000
) -> Variant:
	if not _pending_geotag_promise.is_empty():
		return null

	if export_path.is_empty():
		var bad := GeotagImageExportResult.new()
		bad.success = false
		bad.error = "export_path is required."
		return bad

	var req_id := _random_request_id()
	var payload := JSON.stringify({
		"requestId": req_id,
		"lat": latitude,
		"lon": longitude,
		"exportPath": export_path,
		"sourcePath": source_image_path if not source_image_path.is_empty() else null,
	})

	_pending_geotag_request_id = req_id
	_pending_geotag_promise = [null]
	send_command(-2, "GEOTAG_IMAGE:%s" % payload)

	var tree := _get_tree()
	if tree == null:
		_pending_geotag_promise.clear()
		_pending_geotag_request_id = ""
		return null

	var timer := tree.create_timer(timeout_ms / 1000.0)
	while _pending_geotag_promise.size() > 0 and _pending_geotag_promise[0] == null:
		await tree.process_frame
		if timer.time_left <= 0.0:
			break

	var result: GeotagImageExportResult = null
	if _pending_geotag_promise.size() > 0:
		result = _pending_geotag_promise[0]
	_pending_geotag_promise.clear()
	_pending_geotag_request_id = ""
	return result


func send_layout_async(target_player_id: int, layout_data: Variant) -> void:
	if _is_sending_large_data:
		return

	var merged: Dictionary = {}
	if layout_data is Dictionary:
		merged = layout_data.duplicate(true)
	elif layout_data is String and not layout_data.is_empty():
		var parsed = JSON.parse_string(layout_data)
		if parsed is Dictionary:
			merged = parsed
		else:
			return
	else:
		return

	merged["gameId"] = _game_id
	merged["version"] = _version
	var json_string := JSON.stringify(merged)
	var inline_layout := "LAYOUT:%s" % json_string
	if inline_layout.to_utf8_buffer().size() > MAX_INLINE_LAYOUT_UTF8_BYTES:
		await send_large_data_async(target_player_id, json_string)
	else:
		send_command(target_player_id, inline_layout)


func send_large_data_async(target_player_id: int, full_string: String) -> void:
	if _is_sending_large_data:
		return

	_current_transfer_id += 1
	var session_id := _current_transfer_id
	_is_sending_large_data = true
	send_command(target_player_id, "START_MSG")

	var i := 0
	while i < full_string.length():
		if session_id != _current_transfer_id:
			return
		var end := mini(i + CHUNK_SIZE, full_string.length())
		send_command(target_player_id, "CHUNK:%s" % full_string.substr(i, end - i))
		i = end
		var tree := _get_tree()
		if tree:
			await tree.create_timer(0.05).timeout

	if session_id == _current_transfer_id:
		send_command(target_player_id, "END_MSG")

	if session_id == _current_transfer_id:
		_is_sending_large_data = false


func disconnect_websocket_async() -> void:
	_connect_generation += 1
	_teardown_socket()
	if _lifecycle != ControllerServerState.COOLDOWN \
			and _lifecycle != ControllerServerState.STOPPING:
		_set_state(ControllerServerState.STOPPED)


func disconnect_websocket() -> void:
	disconnect_websocket_async()


func shutdown_server_async() -> void:
	if _lifecycle == ControllerServerState.STOPPING:
		return
	if _lifecycle == ControllerServerState.STOPPED \
			and not _server_started and not _process_launch_ok and _server_pid <= 0:
		if get_remaining_cooldown_ms() > 0:
			var rem := get_remaining_cooldown_ms()
			_set_state(ControllerServerState.COOLDOWN, rem)
			_emit_cooldown(rem)
		return

	_suppress_connection_loss_notifications = true
	_is_manual_disconnect = true
	_connect_generation += 1
	_unregister_from_main_thread_pump()
	_discard_pending_events()
	_cancel_reconnect_timer()
	_cancel_connect_delay_timer()
	_set_state(ControllerServerState.STOPPING)
	_process_launch_ok = false

	print("[PhoneController] Initiating shutdown via SHUTDOWN...")
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		var err := _socket.send_text("SYSTEM:SHUTDOWN")
		if err != OK:
			push_warning("[PhoneController] SHUTDOWN send failed: error %d" % err)
		_flush_websocket_blocking(500)
		_wait_for_websocket_closed_blocking(10000)

	_teardown_socket()
	_server_started = false
	_server_pid = -1
	_complete_shutdown()
	unbind_options_callbacks()


func disable_async() -> void:
	unbind_options_callbacks()
	await shutdown_server_async()


func Dispose() -> void:
	_unregister_from_main_thread_pump()
	await disable_async()


func _resolve_server_exe() -> Dictionary:
	var dirs: PackedStringArray = []
	if not server_exe_directory.is_empty():
		dirs.append(server_exe_directory.strip_edges())

	var exe_dir := OS.get_executable_path().get_base_dir()
	if not exe_dir.is_empty():
		dirs.append(exe_dir)

	dirs.append(ProjectSettings.globalize_path("res://addons/ExerSyncKit/server"))
	if Engine.is_editor_hint():
		dirs.append(ProjectSettings.globalize_path(
			"res://../../../pc-server/Server.Ble/bin/Debug/net9.0-windows10.0.19041.0"
		))

	for dir in dirs:
		if dir.is_empty():
			continue
		var candidate := dir.path_join(server_exe_name)
		if FileAccess.file_exists(candidate):
			return {"path": candidate, "dir": dir}

	return {}


func _establish_connection() -> void:
	if _is_manual_disconnect or _suppress_connection_loss_notifications:
		return
	if _socket_open and _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return
	if _is_connecting:
		return

	var tree := _get_tree()
	if tree == null:
		push_error("[PhoneController] SceneTree not ready for WebSocket connection.")
		return

	if _socket != null:
		_teardown_socket()
	_socket_open = false
	_is_connecting = false

	var generation := _connect_generation
	tree.create_timer(0.05).timeout.connect(func() -> void:
		if generation != _connect_generation:
			return
		_establish_connection_core()
	, CONNECT_ONE_SHOT)


func _establish_connection_core() -> void:
	if _is_manual_disconnect or _suppress_connection_loss_notifications:
		return
	if _socket_open and _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return
	if _is_connecting:
		return
	if _get_tree() == null:
		return

	print("[PhoneController] Connecting %s…" % _url)
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_url)
	if err != OK:
		push_warning("[PhoneController] connect_to_url failed: error %d" % err)
		_teardown_socket()
		_error_occurred(err)
		if _should_report_connection_loss():
			if _is_server_still_running():
				_schedule_reconnect()
			else:
				_notify_server_unavailable("Unable to connect because server is not running.")
		return
	_is_connecting = true


func _on_websocket_opened() -> void:
	if _socket_open:
		return
	_cancel_reconnect_timer()
	_socket_open = true
	_is_connecting = false
	_server_started = true
	_set_state(ControllerServerState.RUNNING)
	print("[PhoneController] WebSocket connected.")
	OnConnected.emit()


func _drain_incoming_packets() -> void:
	if _socket == null:
		return
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		# Server sends UTF-8 JSON via WebSocketSharp Send(byte[]) → binary frames.
		_enqueue_lines(packet.get_string_from_utf8())


func _teardown_socket() -> void:
	_cancel_reconnect_timer()
	_is_connecting = false
	if _socket != null:
		var ws_state := _socket.get_ready_state()
		if ws_state != WebSocketPeer.STATE_CLOSED:
			_socket.close()
		_socket = null
	_socket_open = false
	_buffer = ""
	connected_controllers.clear()


func _handle_socket_closed() -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		return

	_abort_ongoing_transfer()
	_socket = null
	_socket_open = false
	_is_connecting = false
	connected_controllers.clear()

	if _lifecycle == ControllerServerState.STOPPING:
		_server_started = false
		_server_pid = -1
		_complete_shutdown()
		return

	if _lifecycle != ControllerServerState.COOLDOWN \
			and _lifecycle != ControllerServerState.STOPPING:
		_set_state(ControllerServerState.STOPPED)

	if not _should_report_connection_loss():
		return

	push_warning("[PhoneController] WebSocket disconnected.")
	OnDisconnected.emit()
	if _server_started or _process_launch_ok:
		if _is_server_still_running():
			_schedule_reconnect()
		else:
			_notify_server_unavailable("Server process is not running.")


func _should_report_connection_loss() -> bool:
	return not _is_manual_disconnect and not _suppress_connection_loss_notifications


func _notify_server_unavailable(reason: String) -> void:
	if not _should_report_connection_loss():
		return
	_process_launch_ok = false
	_server_started = false
	push_warning("[PhoneController] Server unavailable. %s" % reason)
	ServerUnavailable.emit(reason)


func _schedule_reconnect() -> void:
	if _is_manual_disconnect or _suppress_connection_loss_notifications:
		return
	if _socket_open or _is_connecting:
		return
	if not _server_started and not _process_launch_ok:
		return
	if not _is_server_still_running():
		_notify_server_unavailable("Server process is not running.")
		return
	if _reconnect_timer != null:
		return

	var tree := _get_tree()
	if tree == null:
		return

	_reconnect_timer = tree.create_timer(3.0)
	_reconnect_timer.timeout.connect(func() -> void:
		_reconnect_timer = null
		if not _should_report_connection_loss():
			return
		if not _is_server_still_running():
			_notify_server_unavailable("Server process is not running.")
			return
		_connect_generation += 1
		_establish_connection()
		, CONNECT_ONE_SHOT)


func _clear_server_process_state() -> void:
	_process_launch_ok = false
	_server_started = false
	_server_pid = -1


func _is_server_exe_running_windows() -> bool:
	var output: Array = []
	var err := OS.execute(
		"cmd",
		["/C", "tasklist /FI \"IMAGENAME eq %s\" /NH" % server_exe_name],
		output,
		true,
		false
	)
	if err != 0:
		return true
	var text := ""
	for line in output:
		text += str(line)
	if server_exe_name.to_lower() in text.to_lower():
		return true
	return false


func _is_server_still_running() -> bool:
	if _server_pid > 0:
		if OS.is_process_running(_server_pid):
			return true
		_clear_server_process_state()
		return false

	if not _process_launch_ok:
		return false

	if OS.get_name() == "Windows":
		if _is_server_exe_running_windows():
			return true
		_clear_server_process_state()
		return false

	return true


func _enqueue_lines(text: String) -> void:
	if text.is_empty():
		return
	_buffer += text
	var idx := _buffer.find("\n")
	while idx >= 0:
		var line := _buffer.substr(0, idx).strip_edges()
		_buffer = _buffer.substr(idx + 1)
		if not line.is_empty():
			_line_queue.append(line)
		idx = _buffer.find("\n")


func _process_one_line(line: String) -> void:
	var parsed = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	var data: Dictionary = parsed
	var msg_type: String = str(data.get("type", data.get("Type", "")))
	var player_id := int(data.get("playerId", data.get("PlayerId", -1)))
	
	if msg_type == "status":
		var value: String = str(data.get("value", data.get("Value", "")))
		if value == "DISCONNECTED":
			connected_controllers.erase(player_id)
			_abort_ongoing_transfer()
			OnControllerDisconnected.emit(player_id)
		elif value == "CONNECTED":
			_handle_controller_connected(player_id)
	elif msg_type == "command":
		var value: String = str(data.get("value", data.get("Value", "")))
		if value == "PAUSE":
			OnPause.emit()
		elif value == "RESUME":
			OnResume.emit()
		elif value == "NEED_LAYOUT" and _layout_json != null:
			await send_layout_async(player_id, _layout_json)
	elif msg_type == "stepCount":
		var step_value := int(data.get("value", data.get("Value", 0)))
		var rid: String = str(data.get("requestId", data.get("RequestId", "")))
		if not _pending_step_promise.is_empty() \
				and (rid.is_empty() or rid == _pending_step_request_id):
			_pending_step_promise[0] = step_value
	elif msg_type == "geotagImage":
		var rid: String = str(data.get("requestId", data.get("RequestId", "")))
		if not _pending_geotag_promise.is_empty() \
				and (rid.is_empty() or rid == _pending_geotag_request_id):
			var result := GeotagImageExportResult.new()
			result.success = bool(data.get("success", data.get("Success", false)))
			result.export_path = str(data.get("exportPath", data.get("ExportPath", "")))
			result.error = str(data.get("error", data.get("Error", "")))
			_pending_geotag_promise[0] = result
	elif msg_type == "input":
		var state := InputState.from_dict(data)
		var input_player_id := state.player_id
		if input_player_id >= 0 and not connected_controllers.has(input_player_id):
			_handle_controller_connected(input_player_id)
		OnInput.emit(input_player_id, state)


func _handle_controller_connected(player_id: int) -> void:
	if player_id < 0:
		return
	if not connected_controllers.has(player_id):
		connected_controllers.append(player_id)
	print(
		"[PhoneController] Phone player %d connected." % player_id
	)
	if _layout_json != null:
		send_command(player_id, "CONNECT_GAME:%s:%d" % [_game_id, _version])
	OnControllerConnected.emit(player_id)


func _set_state(state: ControllerServerState, remaining_cooldown_ms: int = 0) -> void:
	if _lifecycle == state:
		return
	_lifecycle = state
	if remaining_cooldown_ms > 0:
		print("[PhoneController] State: %s (retry in %d ms)" % [_state_name(state), remaining_cooldown_ms])
	else:
		print("[PhoneController] State: %s" % _state_name(state))
	StateChanged.emit(state, remaining_cooldown_ms)


func _complete_shutdown() -> void:
	if _lifecycle != ControllerServerState.STOPPING:
		return
	_set_state(ControllerServerState.STOPPED)
	_start_restart_cooldown()


func _start_restart_cooldown() -> void:
	_cooldown_until_ms = Time.get_ticks_msec() + MIN_RESTART_DELAY_MS
	var rem := get_remaining_cooldown_ms()
	Cooldown.emit(rem)
	_set_state(ControllerServerState.COOLDOWN, rem)

	var tree := _get_tree()
	if tree:
		_cooldown_timer = tree.create_timer(rem / 1000.0 + 0.02)
		_cooldown_timer.timeout.connect(func() -> void:
			_cooldown_timer = null
			if get_remaining_cooldown_ms() <= 0 and _lifecycle == ControllerServerState.COOLDOWN:
				_set_state(ControllerServerState.STOPPED)
		, CONNECT_ONE_SHOT)


func _abort_ongoing_transfer() -> void:
	_current_transfer_id += 1
	_is_sending_large_data = false


func _emit_cooldown(remaining_ms: int) -> void:
	Cooldown.emit(remaining_ms)


func _error_occurred(err: Variant) -> void:
	Error.emit(err)


func _discard_pending_events() -> void:
	_line_queue.clear()
	_buffer = ""
	_pending_step_promise.clear()
	_pending_step_request_id = ""
	_pending_geotag_promise.clear()
	_pending_geotag_request_id = ""


func _flush_websocket_blocking(duration_ms: int) -> void:
	if _socket == null:
		return
	var end_ms := Time.get_ticks_msec() + duration_ms
	while Time.get_ticks_msec() < end_ms and _socket != null:
		_socket.poll()
		OS.delay_msec(10)


func _wait_for_websocket_closed_blocking(timeout_ms: int) -> void:
	if _socket == null:
		return
	var end_ms := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < end_ms and _socket != null:
		_socket.poll()
		var state := _socket.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED or state == WebSocketPeer.STATE_CLOSING:
			return
		OS.delay_msec(10)


func _get_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _get_main_thread_pump() -> Node:
	var tree := _get_tree()
	if tree == null or not tree.root.has_node(MAIN_THREAD_PUMP_AUTOLOAD):
		return null
	return tree.root.get_node(MAIN_THREAD_PUMP_AUTOLOAD)


func _register_with_main_thread_pump() -> void:
	var pump := _get_main_thread_pump()
	if pump == null:
		push_error(
			"[ExerSyncKit] ExerSyncKitMainThreadPump autoload missing. "
			+ "Add to Project Settings → Autoload, or enable the ExerSyncKit plugin."
		)
		return
	pump.register_input(self)


func _unregister_from_main_thread_pump() -> void:
	var pump := _get_main_thread_pump()
	if pump:
		pump.unregister_input(self)


func _cancel_reconnect_timer() -> void:
	if _reconnect_timer != null:
		_reconnect_timer = null


func _cancel_connect_delay_timer() -> void:
	if _connect_delay_timer != null:
		_connect_delay_timer = null


func _random_request_id() -> String:
	return "%08x" % (randi() & 0xFFFFFFFF)


func _state_name(state: ControllerServerState) -> String:
	match state:
		ControllerServerState.STOPPED:
			return "stopped"
		ControllerServerState.STARTING:
			return "starting"
		ControllerServerState.RUNNING:
			return "running"
		ControllerServerState.STOPPING:
			return "stopping"
		ControllerServerState.COOLDOWN:
			return "cooldown"
		_:
			return "unknown"
