extends Node
## Autoload: NetworkManager
##
## Todo lo que tiene que ver con "quién juega y por dónde llegan sus jugadas".
## El reparto de responsabilidades es siempre el mismo, se juegue solo o en red:
##
##   El ANFITRIÓN es el único que toca GameLogic. Los demás sólo PIDEN cosas
##   ("quiero robar del mazo") y reciben de vuelta el estado ya resuelto.
##
## Eso vale igual para una partida contra bots (donde el anfitrión eres tú y no
## hay red de por medio) que para una online. Por eso `request_*` son funciones
## normales: si eres el anfitrión se aplican aquí mismo, y si no, se mandan.
##
## ---------- SOBRE EL TRANSPORTE ----------
##
## Antes esto era WebRTC con un servidor de señalización. Ya no: ahora es un
## WebSocket contra un relé (`server/server.js`) que reenvía paquetes entre los
## de la misma sala. El cambio es porque las plantillas WEB de Godot no pueden
## cargar extensiones nativas, y WebRTC necesita una — o sea que por ahí el
## navegador se quedaba fuera para siempre. Además WebRTC habría exigido un
## servidor TURN aparte para funcionar en redes móviles. Con un relé va todo
## con lo que Godot trae de serie, y en un juego por turnos la latencia sobra.
##
## Los datos van en tramas BINARIAS con `var_to_bytes`, no en JSON. Con JSON los
## enteros vuelven convertidos en decimales y cosas como
## `state.players[turn_index]` revientan al indexar.

signal game_state_updated
signal connection_error(message: String)
signal joined_as(peer_id: int)
signal connection_changed
## Cuántos hay conectados ahora mismo. Lo pide el menú para poder avisar de si
## merece la pena buscar partida.
signal status_updated(info: Dictionary)

## Tope de jugadores en una mesa, humanos y bots juntos. Cuatro es lo que
## admite el reparto de la pantalla (los rivales van en fila arriba) y también
## lo que comprueba el relé por su cuenta.
const MAX_PLAYERS: int = 4

## Los bots no ocupan un hueco de conexión, así que sus identificadores viven
## lejos de los que reparte el relé (1, 2, 3...) y no pueden chocar.
const BOT_BASE_ID: int = 101
const BOT_NAMES: Array[String] = ["Ana", "Bruno", "Clara", "Diego", "Elena"]

## Dirección del relé. Viene puesta de fábrica para que el jugador no tenga que
## configurar nada: crear partida y unirse funcionan de entrada.
##
## Se puede cambiar sin reexportar la aplicación, pero por un acceso OCULTO
## (cinco toques en la línea pequeña de la portada), no por un botón del menú:
## a un jugador normal la palabra "servidor" sólo le desconcierta. Está ahí por
## si algún día el relé se muda de sitio.
const DEFAULT_RELAY_URL := "wss://dutch-relay.onrender.com/"
const SETTINGS_PATH := "user://settings.cfg"

var relay_url: String = DEFAULT_RELAY_URL

var my_id: int = -1
var my_name: String = ""
var is_host: bool = false
var room_code: String = ""

## Partida sin red: tú de anfitrión y el resto bots.
var local_mode: bool = false
## Partida por el relé (siendo anfitrión o invitado).
var online: bool = false

enum Link { OFFLINE, CONNECTING, READY }
var link: int = Link.OFFLINE

var _ws: WebSocketPeer = null
var _hello: Dictionary = {}
var _last_ws_state: int = WebSocketPeer.STATE_CLOSED

## Plazo para acabar de entrar en una partida (conectar + que el servidor te
## siente en una mesa). Sin esto, un servidor que no contesta deja la pantalla
## en "Buscando partida..." para siempre, que es peor que un error: el jugador
## no sabe si esperar o salirse.
##
## Es generoso a propósito: el servidor gratuito se duerme y puede tardar medio
## minuto en despertar. Mientras tanto la sala ya dice que está conectando.
const CONNECT_TIMEOUT_MS: int = 40000
var _connect_deadline_ms: int = 0

## ---------- MODO TUTORIAL ----------
##
## El tutorial es una partida local igual que la de práctica, pero con el
## reparto colocado y el rival a guion. Dos interruptores:
##
## - tutorial_mode: el rival deja de improvisar. Siempre roba del mazo y
##   siempre tira lo robado, así que la carta que cae al descarte es
##   exactamente la que el guion puso en el mazo. Nunca quema, nunca canta
##   Dutch y nunca cambia cartas de su mano.
## - tutorial_bots_paused: congela al rival. El guion lo descongela sólo en los
##   pasos en los que toca verle jugar, de forma que mientras el aprendiz lee
##   el globo de texto no le pasa nada por la espalda.
var tutorial_mode: bool = false
var tutorial_bots_paused: bool = false

## Cuál de MIS cartas se lleva el rival en el intercambio a ciegas del 11. En
## una partida normal es al azar, pero el guion necesita saberlo para poder
## contar después qué ha pasado.
const TUTORIAL_BLIND_SLOT: int = 1

var _bot_running: bool = false
var _bot_next_action_at_ms: int = 0

func _ready() -> void:
	set_process(true)
	_load_settings()
	GameLogic.state_changed.connect(_on_state_changed)

func _process(_delta: float) -> void:
	_poll_socket()
	if is_host and _bot_running:
		# Las quemadas van aparte del turno: quemar es cosa de todos y en
		# cualquier momento, no sólo de quien tiene el turno.
		_plan_bot_burns()
		_run_bot_burns()
		_run_bot_turn()

## ---------- AJUSTES ----------

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var saved := str(cfg.get_value("net", "relay_url", ""))
	if saved != "":
		relay_url = saved

func set_relay_url(url: String) -> void:
	relay_url = url.strip_edges()
	# Se lee el archivo antes de escribir: lo comparte con el volumen de la
	# música, y guardarlo a pelo borraría ese ajuste.
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("net", "relay_url", relay_url)
	cfg.save(SETTINGS_PATH)

func relay_url_looks_valid() -> bool:
	return relay_url.begins_with("ws://") or relay_url.begins_with("wss://")

## ---------- CUÁNTA GENTE HAY ----------
##
## Se consulta por HTTP normal, no por WebSocket: mantener una conexión abierta
## desde el menú sólo para contar cabezas gastaría batería y, con el servidor
## gratuito, lo tendría despierto (y consumiendo horas) todo el rato.
##
## Y NO se consulta en bucle: sólo al entrar al menú y cuando el jugador toca el
## contador. Un sondeo cada pocos segundos impediría que el servidor se durmiera
## nunca, que es justo lo que agota la cuota del plan gratuito.
##
## Efecto secundario que viene bien: esta consulta DESPIERTA al servidor si
## estaba dormido, así que cuando el jugador pulse "Buscar partida" ya está en
## marcha.

var last_status: Dictionary = {}
var _http: HTTPRequest = null

func fetch_status() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		# Generoso: el servidor gratuito tarda en desperezarse.
		_http.timeout = 30.0
		add_child(_http)
		_http.request_completed.connect(_on_status_response)
	# Si ya hay una consulta en marcha, no se encima otra.
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var url := status_url()
	if url == "":
		return
	if _http.request(url) != OK:
		last_status = {"error": true}
		status_updated.emit(last_status)

## La dirección del relé es de WebSocket (wss://); la consulta va por el mismo
## sitio pero en HTTP, así que se traduce el esquema.
func status_url() -> String:
	var u := relay_url
	if u.begins_with("wss://"):
		u = "https://" + u.substr(6)
	elif u.begins_with("ws://"):
		u = "http://" + u.substr(5)
	else:
		return ""
	if not u.ends_with("/"):
		u += "/"
	return u + "status"

func _on_status_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		last_status = {"error": true}
		status_updated.emit(last_status)
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		last_status = {"error": true}
	else:
		last_status = json.data
	status_updated.emit(last_status)

## ---------- PARTIDA LOCAL ----------

func start_local_game(name: String) -> void:
	_begin_offline(name, "LOCAL")
	tutorial_mode = false
	tutorial_bots_paused = false
	GameLogic.burn_window_ms = GameLogic.BURN_WINDOW_MS
	for i in range(3):
		GameLogic.add_player(BOT_BASE_ID + i, BOT_NAMES[i], true)
	GameLogic.start_game(1)
	_after_start()

## Partida del tutorial: un solo rival (los turnos se alternan y no hay que
## esperar a tres bots entre lección y lección) y el reparto puesto a mano.
## Arranca con el rival congelado: descongelarlo es cosa del guion.
func start_tutorial_game(name: String, hands: Array, deck: Array, rival: String) -> void:
	_begin_offline(name, "TUTORIAL")
	tutorial_mode = true
	tutorial_bots_paused = true
	# Ventana de reacción corta: aquí nadie compite por quemar, y cuatro
	# segundos de botón en gris después de cada carta se hacen eternos cuando
	# encima el globo de texto te está pidiendo que robes.
	GameLogic.burn_window_ms = 1500
	GameLogic.add_player(BOT_BASE_ID, rival, true)
	GameLogic.start_scripted_game(1, hands, deck)
	_after_start()

func _begin_offline(name: String, room: String) -> void:
	_close_socket()
	local_mode = true
	online = false
	link = Link.OFFLINE
	_bot_running = true
	my_name = name
	room_code = room
	is_host = true
	my_id = 1
	GameLogic.reset_lobby(1, name)

func _after_start() -> void:
	_begin_bot_round()
	game_state_updated.emit()

## Todo lo que hay que hacer al empezar una mano: poner listos a los bots y
## borrarles la memoria de la mano anterior. Vale igual para la primera partida,
## para una revancha y para una online, que es justo por lo que está aquí en vez
## de repetido en cada sitio.
func _begin_bot_round() -> void:
	_ready_up_bots()
	_bot_running = is_host and _has_bots()
	_bot_seen_discard = ""
	_bot_burn_plans.clear()
	_bot_next_action_at_ms = Time.get_ticks_msec() + 700

## ---------- PARTIDA ONLINE ----------
##
## Tres maneras de entrar, y las tres acaban en el mismo sitio:
##
##   host_game()    creas una mesa y repartes el código a quien tú quieras
##   join_game()    entras en la mesa de un amigo con su código
##   find_public()  buscas mesa con desconocidos
##
## En las dos primeras se sabe desde el principio si eres anfitrión o invitado.
## En la tercera NO: eso lo decide el servidor según haya mesa abierta o no, y
## hasta que conteste no se sabe. Por eso `is_host` se fija al recibir la
## respuesta y no antes.

## ¿Esta mesa se ofrece a desconocidos? Sólo importa siendo anfitrión.
var room_is_public: bool = false
## Estamos buscando mesa y aún no sabemos si acabaremos de anfitrión.
var searching: bool = false

func host_game(name: String, public: bool = false) -> void:
	room_is_public = public
	_start_online(name, "", true, {"t": "host", "name": name, "public": public})

func join_game(code: String, name: String) -> void:
	room_is_public = false
	_start_online(name, code.to_upper(), false, {"t": "join", "room": code.to_upper(), "name": name})

## Buscar partida pública. Se le pregunta al servidor si hay mesa abierta: si la
## hay te sienta en ella, y si no, abres tú una y esperas. Nunca se acaba en un
## "no hay partidas" sin salida, que es lo que mata a un juego con pocos
## jugadores.
func find_public_game(name: String) -> void:
	room_is_public = true
	searching = true
	_start_online(name, "", false, {"t": "quick"})

func _start_online(name: String, code: String, as_host: bool, hello: Dictionary) -> void:
	if not relay_url_looks_valid():
		connection_error.emit("No hay servidor configurado para jugar online.")
		return
	_close_socket()
	local_mode = false
	tutorial_mode = false
	tutorial_bots_paused = false
	GameLogic.burn_window_ms = GameLogic.BURN_WINDOW_MS
	online = true
	is_host = as_host
	# Hasta que el relé conteste no somos nadie: si aquí se diera por hecho que
	# el anfitrión es el 1, la pantalla se dibujaría antes de tiempo con datos
	# inventados.
	my_id = -1
	my_name = name
	room_code = code
	_bot_running = as_host
	GameLogic.state = {}
	_hello = hello
	_told_relay_playing = false
	_connect_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	link = Link.CONNECTING
	connection_changed.emit()
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(relay_url)
	if err != OK:
		_fail("No se pudo conectar. Revisa tu conexión a internet.")

func leave_game() -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify({"t": "bye"}))
		_ws.poll()
	_close_socket()
	local_mode = false
	online = false
	link = Link.OFFLINE
	_bot_running = false
	tutorial_mode = false
	tutorial_bots_paused = false
	GameLogic.burn_window_ms = GameLogic.BURN_WINDOW_MS
	is_host = false
	room_is_public = false
	searching = false
	room_code = ""
	my_id = -1
	GameLogic.state = {}
	connection_changed.emit()

func _close_socket() -> void:
	if _ws != null:
		_ws.close()
		_ws = null
	_last_ws_state = WebSocketPeer.STATE_CLOSED
	_hello = {}

## Se recoge TODO antes de avisar, y no al revés. Quien escucha el aviso mira
## el estado para decidir qué hacer (la interfaz vuelve al menú si ya no hay
## partida), así que si se avisara primero se encontraría con datos de una
## conexión que en realidad ya está muerta — y se quedaba encallada en la sala
## de espera con un mensaje de error encima.
func _fail(msg: String) -> void:
	_close_socket()
	online = false
	searching = false
	room_is_public = false
	link = Link.OFFLINE
	_bot_running = false
	connection_changed.emit()
	connection_error.emit(msg)

## ---------- SOCKET ----------

func _poll_socket() -> void:
	if _ws == null:
		return
	if link != Link.READY and Time.get_ticks_msec() > _connect_deadline_ms:
		_fail("No se pudo entrar en la partida. Inténtalo otra vez en unos segundos.")
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st != _last_ws_state:
		_last_ws_state = st
		if st == WebSocketPeer.STATE_OPEN and not _hello.is_empty():
			_ws.send_text(JSON.stringify(_hello))
			_hello = {}
		elif st == WebSocketPeer.STATE_CLOSED:
			var code := _ws.get_close_code()
			# El servidor gratuito se duerme si lleva un rato sin usarse y tarda
			# unos segundos en despertar, así que el primer intento puede fallar
			# sin que pase nada raro. El mensaje invita a reintentar en vez de
			# dar a entender que está roto.
			_fail("Se perdió la conexión con el servidor." if code != -1 else
				"No se pudo conectar. Revisa tu internet y vuelve a intentarlo en unos segundos.")
			return
	while _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and _ws.get_available_packet_count() > 0:
		# El orden importa: was_string_packet() habla del ÚLTIMO paquete
		# OBTENIDO, así que preguntarlo antes de get_packet() responde sobre el
		# anterior. Así se estaban leyendo los mensajes de control como si
		# fueran datos binarios.
		var pkt := _ws.get_packet()
		if _ws.was_string_packet():
			_on_control(pkt.get_string_from_utf8())
		else:
			_on_data(pkt)

func _on_control(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = json.data
	match str(msg.get("t", "")):
		"match":
			# Respuesta a la búsqueda: o hay mesa abierta, o abrimos nosotros.
			searching = false
			var found := str(msg.get("room", ""))
			if found != "":
				_ws.send_text(JSON.stringify({"t": "join", "room": found, "name": my_name}))
			else:
				is_host = true
				_bot_running = true
				_ws.send_text(JSON.stringify({"t": "host", "name": my_name, "public": true}))
		"hosted":
			_connect_deadline_ms = 0x7FFFFFFF
			room_code = str(msg.get("room", room_code))
			room_is_public = bool(msg.get("public", false))
			is_host = true
			_bot_running = true
			my_id = int(msg.get("id", 1))
			link = Link.READY
			GameLogic.reset_lobby(my_id, my_name)
			connection_changed.emit()
			joined_as.emit(my_id)
		"joined":
			_connect_deadline_ms = 0x7FFFFFFF
			room_code = str(msg.get("room", room_code))
			is_host = false
			_bot_running = false
			my_id = int(msg.get("id", -1))
			link = Link.READY
			connection_changed.emit()
			joined_as.emit(my_id)
		"peer_join":
			if not is_host:
				return
			GameLogic.add_player(int(msg.get("id", -1)), str(msg.get("name", "Jugador")), false)
		"peer_left":
			if is_host:
				_on_peer_left(int(msg.get("id", -1)))
		"host_left":
			_fail("El anfitrión ha cerrado la partida.")
		"error":
			_fail(str(msg.get("m", "Error del servidor.")))

## Alguien se ha caído. En la sala de espera basta con quitarlo; en mitad de una
## partida NO se le puede echar sin más, porque sus cartas cuentan y la ronda se
## quedaría esperándole para siempre: se le deja la mano y pasa a jugarla un
## bot. Con móviles esto no es raro (basta con que se bloquee la pantalla).
func _on_peer_left(pid: int) -> void:
	if pid <= 0 or GameLogic.state.is_empty():
		return
	if str(GameLogic.state.get("status", "")) == "lobby":
		GameLogic.remove_player(pid)
		return
	if GameLogic.make_bot(pid):
		_bot_running = true

func _send_data(target: int, payload: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var body := var_to_bytes(payload)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_s32(0, target)
	out.append_array(body)
	_ws.put_packet(out)

func _on_data(pkt: PackedByteArray) -> void:
	if pkt.size() < 5:
		return
	var sender := pkt.decode_s32(0)
	# `allow_objects` se queda en false (es el valor por defecto): un paquete
	# que llegue de fuera JAMÁS debe poder construir objetos.
	var payload: Variant = bytes_to_var(pkt.slice(4))
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = payload
	match str(msg.get("k", "")):
		"state":
			if is_host:
				return
			var s: Variant = msg.get("s")
			if typeof(s) != TYPE_DICTIONARY:
				return
			GameLogic.state = s
			game_state_updated.emit()
		"req":
			if not is_host:
				return
			_apply_request(sender, str(msg.get("op", "")), msg.get("args", {}))

## ---------- ESTADO ----------

## Lo último que se le dijo al relé sobre si esta mesa ya está jugando. Se
## guarda para no repetírselo en cada cambio de estado, que son muchos.
var _told_relay_playing: bool = false

func _on_state_changed() -> void:
	if is_host and online:
		_send_data(0, {"k": "state", "s": GameLogic.state})
		# Una mesa pública deja de ofrecerse en cuanto se reparte: si no, al que
		# está buscando lo sentarían en una partida ya empezada.
		var playing: bool = str(GameLogic.state.get("status", "")) != "lobby"
		if playing != _told_relay_playing:
			_told_relay_playing = playing
			if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				_ws.send_text(JSON.stringify({"t": "room", "playing": playing}))
	game_state_updated.emit()

## ---------- PETICIONES ----------
##
## La interfaz llama a estas y ya está: no tiene que saber si hay red o no.

func _send_request(op: String, args: Dictionary = {}) -> void:
	if is_host:
		_apply_request(my_id, op, args)
	else:
		_send_data(1, {"k": "req", "op": op, "args": args})

func request_start_game() -> void: _send_request("start_game")
func request_peek(idx: int) -> void: _send_request("peek", {"idx": idx})
func request_player_ready() -> void: _send_request("ready")
func request_draw_deck() -> void: _send_request("draw_deck")
func request_draw_discard() -> void: _send_request("draw_discard")
func request_swap(idx: int) -> void: _send_request("swap", {"idx": idx})
func request_discard_drawn() -> void: _send_request("discard_drawn")
func request_burn(idx: int) -> void: _send_request("burn", {"idx": idx})
func request_dutch() -> void: _send_request("dutch")
func request_ten_pick(target_id: int, idx: int) -> void: _send_request("ten_pick", {"target": target_id, "idx": idx})
func request_ten_ack() -> void: _send_request("ten_ack")
func request_eleven_target(target_id: int) -> void: _send_request("eleven_target", {"target": target_id})
func request_eleven_target_slot(idx: int) -> void: _send_request("eleven_target_slot", {"idx": idx})
func request_eleven_my_slot(idx: int) -> void: _send_request("eleven_my_slot", {"idx": idx})
func request_play_again() -> void: _send_request("play_again")
func request_lobby_ready(ready: bool) -> void: _send_request("lobby_ready", {"ready": ready})
func request_add_bot() -> void: _send_request("add_bot")
func request_remove_bot() -> void: _send_request("remove_bot")

## Único punto donde una petición se convierte en una jugada. Ojo: `pid` es
## SIEMPRE quien la pidió de verdad (el remitente del paquete), nunca un dato
## que venga dentro del mensaje. Si no, cualquiera podría jugar por otro.
func _apply_request(pid: int, op: String, args: Variant) -> void:
	var a: Dictionary = args if typeof(args) == TYPE_DICTIONARY else {}
	match op:
		"start_game":
			# Los bots tienen que mirar sus cartas y declararse listos igual que
			# los humanos, o la fase de mirar se queda esperándoles para siempre.
			# Esto sólo se hacía al arrancar una partida local.
			if GameLogic.start_game(pid):
				_begin_bot_round()
		"peek": GameLogic.player_peek(pid, int(a.get("idx", -1)))
		"ready": GameLogic.player_ready(pid)
		"draw_deck": GameLogic.draw_from_deck(pid)
		"draw_discard": GameLogic.draw_from_discard(pid)
		"swap": GameLogic.resolve_swap(pid, int(a.get("idx", -1)))
		"discard_drawn": GameLogic.resolve_discard_drawn(pid)
		"burn": GameLogic.attempt_burn(pid, int(a.get("idx", -1)))
		"dutch": GameLogic.call_dutch(pid)
		"ten_pick": GameLogic.resolve_ten_pick(pid, int(a.get("target", -1)), int(a.get("idx", -1)))
		"ten_ack": GameLogic.resolve_ten_ack(pid)
		"eleven_target": GameLogic.resolve_eleven_target(pid, int(a.get("target", -1)))
		"eleven_target_slot": GameLogic.resolve_eleven_target_slot(pid, int(a.get("idx", -1)))
		"eleven_my_slot": GameLogic.resolve_eleven_my_slot(pid, int(a.get("idx", -1)))
		"play_again":
			if GameLogic.play_again(pid):
				_begin_bot_round()
		"lobby_ready": GameLogic.set_lobby_ready(pid, bool(a.get("ready", true)))
		"add_bot":
			if GameLogic.add_bot(pid, _free_bot_name()):
				_bot_running = true
		"remove_bot":
			GameLogic.remove_bot(pid)
			_bot_running = _has_bots()

func _free_bot_name() -> String:
	var taken: Array = []
	for p in GameLogic.state.get("players", []):
		taken.append(str(p.get("name", "")))
	for n in BOT_NAMES:
		if not taken.has(n):
			return n
	return "Bot"

## ---------- BOTS ----------
##
## Los bots son jugadores normales de `state.players` con la marca `bot`. Los
## mueve el anfitrión, igual en una partida local que en una online: para el
## resto de la mesa son indistinguibles de un humano lento.

func _is_bot(p: Dictionary) -> bool:
	return bool(p.get("bot", false))

func _has_bots() -> bool:
	for p in GameLogic.state.get("players", []):
		if _is_bot(p):
			return true
	return false

func _is_bot_id(pid: int) -> bool:
	for p in GameLogic.state.get("players", []):
		if int(p.get("id", -1)) == pid:
			return _is_bot(p)
	return false

## Los bots miran sus cartas y se declaran listos solos. Sin esto la fase de
## mirar no terminaría nunca, porque se les estaría esperando.
func _ready_up_bots() -> void:
	if GameLogic.state.get("status", "") != "peek":
		return
	for p in GameLogic.state.players:
		if not _is_bot(p):
			continue
		GameLogic.player_peek(p.id, 0)
		GameLogic.player_peek(p.id, 1)
		GameLogic.player_ready(p.id)

func _hand_size(pid: int) -> int:
	for p in GameLogic.state.get("players", []):
		if p.id == pid:
			return p.hand.size()
	return 1

## Un rival cualquiera que no sea uno mismo. Antes los bots siempre atacaban al
## humano con el 11, que además de previsible era injusto.
func _random_rival(of_id: int) -> int:
	var others: Array = []
	for p in GameLogic.state.get("players", []):
		if p.id != of_id:
			others.append(p.id)
	if others.is_empty():
		return of_id
	return others[randi() % others.size()]

## ---------- QUEMADAS DE LOS BOTS ----------
##
## Los bots no quemaban nunca, así que ganarles era trivial. Ahora, cada vez
## que cae una carta nueva al descarte, cada bot decide si "se acuerda" de
## tener una que case y, si es que sí, la quema tras un tiempo de reacción
## humano. La memoria es deliberadamente imperfecta: con memoria perfecta
## quemarían siempre que pudieran y serían imbatibles.
const BOT_BURN_CHANCE := 0.55

var _bot_seen_discard: String = ""
var _bot_burn_plans: Array = []

func _plan_bot_burns() -> void:
	# En el tutorial el rival no quema nunca: una quemada suya a media lección
	# cambiaría la carta de arriba del descarte y el guion dejaría de cuadrar.
	if tutorial_mode:
		return
	var st: Dictionary = GameLogic.state
	var top: String = str(st.discard[-1]) if st.get("discard", []).size() > 0 else ""
	if top == _bot_seen_discard:
		return
	_bot_seen_discard = top
	_bot_burn_plans.clear()
	if top == "" or not st.get("pending_special", {}).is_empty():
		return
	var top_number := CardData.parse_number(top)
	for p in st.get("players", []):
		if not _is_bot(p):
			continue
		if randf() > BOT_BURN_CHANCE:
			continue
		var has_match := false
		for c in p.hand:
			if CardData.parse_number(str(c)) == top_number:
				has_match = true
				break
		if not has_match:
			continue
		_bot_burn_plans.append({
			"id": p.id,
			"at": Time.get_ticks_msec() + randi_range(600, 2500),
		})

func _run_bot_burns() -> void:
	if _bot_burn_plans.is_empty():
		return
	var now := Time.get_ticks_msec()
	var still: Array = []
	for plan in _bot_burn_plans:
		if now < plan.at:
			still.append(plan)
			continue
		var st: Dictionary = GameLogic.state
		if st.get("status", "") != "playing" or st.discard.is_empty():
			continue
		if not st.get("pending_special", {}).is_empty():
			# Hay un 10 u 11 sin resolver: no se puede quemar todavía, se
			# reintenta en el siguiente tic.
			still.append(plan)
			continue
		# El hueco se busca AHORA y no al planificarlo: entre medias puede
		# haber quemado otro y las posiciones de la mano se habrán movido.
		var top_number := CardData.parse_number(str(st.discard[-1]))
		for p in st.get("players", []):
			if p.id != plan.id:
				continue
			for i in range(p.hand.size()):
				if CardData.parse_number(str(p.hand[i])) == top_number:
					GameLogic.attempt_burn(plan.id, i)
					break
			break
	_bot_burn_plans = still

func _run_bot_turn() -> void:
	if GameLogic.state.get("status", "") != "playing":
		return
	if tutorial_bots_paused:
		return
	if Time.get_ticks_msec() < _bot_next_action_at_ms:
		return
	var state: Dictionary = GameLogic.state
	# Un 10 u 11 sin resolver lo resuelve quien corresponda, que NO es siempre
	# el del turno: un humano puede quemar en el turno de otro y disparar el
	# efecto. Si se resolviera con el identificador equivocado, la llamada no
	# haría nada en silencio y la partida se quedaría colgada ahí.
	var pending: Dictionary = state.get("pending_special", {})
	if not pending.is_empty():
		if pending.type == "10":
			# El 10 sólo lo resuelve quien lo jugó.
			if not _is_bot_id(int(pending.by)):
				return
			if pending.has("peeked_value"):
				GameLogic.resolve_ten_ack(pending.by)
			else:
				GameLogic.resolve_ten_pick(pending.by, pending.by, 0)
		elif pending.type == "11":
			# En el 11 el último paso lo resuelve el RIVAL, así que un bot
			# puede tener que actuar aunque el 11 lo haya jugado un humano.
			var actor: int = GameLogic.eleven_actor(pending)
			if not _is_bot_id(actor):
				return
			if pending.target_id == -1:
				GameLogic.resolve_eleven_target(pending.by, _random_rival(pending.by))
			elif pending.target_slot == -1:
				GameLogic.resolve_eleven_target_slot(pending.by, randi() % max(1, _hand_size(pending.target_id)))
			else:
				GameLogic.resolve_eleven_my_slot(pending.target_id, _blind_slot(_hand_size(pending.by)))
		_bot_next_action_at_ms = Time.get_ticks_msec() + 1000
		return
	var current: Dictionary = state.players[state.turn_index]
	if not _is_bot(current):
		return
	var bot_id: int = current.id
	if tutorial_mode:
		_run_scripted_bot_turn(bot_id, state)
		return
	if not state.active_draw.is_empty():
		if state.active_draw.player_id == bot_id:
			if randi() % 4 == 0:
				GameLogic.resolve_discard_drawn(bot_id)
			else:
				GameLogic.resolve_swap(bot_id, 0)
			_bot_next_action_at_ms = Time.get_ticks_msec() + 1100
		return
	# draw_from_deck/draw_from_discard se niegan en silencio mientras la ventana
	# de reacción sigue abierta; el bot reintenta cada tic, igual que un humano
	# esperaría con los botones en gris.
	if state.dutch_caller_id == -1 and state.get("round_number", 1) >= GameLogic.MIN_DUTCH_ROUND and randi() % 12 == 0:
		GameLogic.call_dutch(bot_id)
	elif not state.discard.is_empty() and not GameLogic.discard_is_burned() \
			and (randi() % 3 == 0 or not GameLogic.deck_can_serve()):
		# Sin comprobar si está quemada, el bot intentaría robar del descarte
		# una y otra vez sin conseguirlo y su turno se quedaría colgado casi un
		# segundo por intento. Y si el mazo ya no da para más, el descarte pasa
		# a ser su única salida en vez de una opción al azar.
		GameLogic.draw_from_discard(bot_id)
	else:
		GameLogic.draw_from_deck(bot_id)
	_bot_next_action_at_ms = Time.get_ticks_msec() + 900

## Turno del rival en el tutorial: robar del mazo y tirar lo robado, siempre.
## Es la jugada más tonta posible, y eso es justo lo que se busca: la carta que
## acaba en el descarte es la que el guion colocó en el mazo, así que la lección
## siguiente puede dar por hecho qué número hay arriba.
func _run_scripted_bot_turn(bot_id: int, state: Dictionary) -> void:
	if not state.active_draw.is_empty():
		if state.active_draw.player_id == bot_id:
			GameLogic.resolve_discard_drawn(bot_id)
			_bot_next_action_at_ms = Time.get_ticks_msec() + 900
		return
	GameLogic.draw_from_deck(bot_id)
	_bot_next_action_at_ms = Time.get_ticks_msec() + 900

## Hueco que se lleva un bot en un intercambio a ciegas. En el tutorial es fijo
## para que el guion pueda contar después qué carta le han quitado a quién.
func _blind_slot(hand_size: int) -> int:
	var n: int = max(1, hand_size)
	if tutorial_mode:
		return clampi(TUTORIAL_BLIND_SLOT, 0, n - 1)
	return randi() % n
