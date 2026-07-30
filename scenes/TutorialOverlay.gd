class_name TutorialOverlay
extends Control
## TutorialOverlay.gd
## Tutorial GUIONIZADO: una partida de verdad, pero con las cartas colocadas a
## mano y un guion encima que sólo deja hacer una cosa en cada momento.
##
## Tres decisiones sostienen todo lo demás:
##
## - El reparto no se baraja (GameLogic.start_scripted_game). Como el guion sabe
##   qué carta va a salir, puede pedir cosas concretas —"cambia el 1 que acabas
##   de robar por tu segunda carta, que es el 12 de copas"— en vez de
##   generalidades. Es la diferencia entre enseñar y describir.
## - El rival va a guion y congelado (NetworkManager.tutorial_mode). Siempre roba
##   del mazo y tira lo robado, nunca quema y nunca canta Dutch, así que la carta
##   de arriba del descarte en cada lección es exactamente la prevista. Sólo se
##   descongela en los pasos en los que toca verle jugar: mientras se lee el
##   globo de texto no pasa nada por la espalda.
## - Cada paso declara qué controles se pueden tocar (`gate`) y Main desactiva
##   todo lo demás. No hace falta adivinar qué habrá pulsado el aprendiz: no
##   puede pulsar nada más.
##
## El guion cubre las once reglas del juego y, sobre todo, las TRES CARTAS
## ESPECIALES, cada una jugada de verdad por el aprendiz: el 10 (mirar una carta
## propia), el 11 (intercambio a ciegas) y el 12 (0 puntos en espadas y oros, 30
## en copas y bastos).

signal finished

## ---------- EL REPARTO TRUCADO ----------
##
## Cada carta está donde está por una razón; cambiar una obliga a repasar el
## guion entero. Las manos van en el orden de state.players: primero la del
## aprendiz, después la del rival.
##
##   Tú:  un 3 bajo que servirá para quemar, el 12 de copas (30 puntos, la peor
##        carta del juego) que aprenderá a soltar, y dos desconocidas.
##   Ana: cartas medias, sin 10 ni 11 ni 12, para que su mano no genere efectos.
const HANDS := [
	["oros-3", "copas-12", "copas-7", "bastos-5"],
	["espadas-4", "bastos-2", "oros-6", "copas-1"],
]

## El mazo, en el orden en que se reparte. Los pares son del aprendiz y los
## impares del rival, porque con dos jugadores los turnos se alternan y el rival
## siempre roba una carta por turno:
##
##   0 espadas-1  yo,  la cambio por el 12 de copas
##   1 copas-3    Ana, la tira y yo quemo mi 3
##   2 espadas-10 yo,  la descarto: efecto del 10
##   3 bastos-6   Ana, la tira (no puedo quemarla, no tengo ningún 6)
##   4 bastos-11  yo,  la descarto: efecto del 11
##   5 oros-7     Ana, la tira
##   6 espadas-12 yo,  el 12 que vale 0: me lo quedo
##   7 bastos-4   Ana, su última vuelta tras mi Dutch
##
## Las cuatro últimas son colchón: no se llegan a usar, están para que una
## carta de penalización imprevista no deje el mazo seco a mitad de lección.
const DECK := [
	"espadas-1", "copas-3", "espadas-10", "bastos-6",
	"bastos-11", "oros-7", "espadas-12", "bastos-4",
	"oros-2", "copas-5", "espadas-6", "oros-10",
]

const RIVAL_NAME := "Ana"

## Un paso del guion.
##
## `gate` son las claves de los controles que se pueden tocar; lo demás queda
## inerte. `done` es la condición que lo supera, y cuando está vacía el paso se
## pasa a mano con el botón (los informativos, para que nadie se los salte sin
## leerlos). `bots` descongela al rival mientras el paso está activo.
class Step:
	var text: String
	var target: String
	var gate: Array
	var done: String
	var bots: bool
	func _init(t: String, tgt: String = "", g: Array = [], d: String = "", b: bool = false) -> void:
		text = t
		target = tgt
		gate = g
		done = d
		bots = b

var _rect_for: Callable
var _set_gate: Callable
var _steps: Array = []
var _index: int = 0
var _t: float = 0.0
var _aborted: bool = false

var _bubble: PanelContainer
var _text_label: Label
var _step_label: Label
var _ok_btn: Button

func setup(rect_for: Callable, set_gate: Callable) -> void:
	_rect_for = rect_for
	_set_gate = set_gate
	_build_steps()
	_build_ui()

## ---------- EL GUION ----------
##
## Líneas cortas a propósito (unos 42 caracteres): el globo se mantiene estrecho
## y así hay mucho más sitio donde colocarlo sin tapar lo que está señalando.

func _build_steps() -> void:
	var take_any: Array = ["modal_11_take_0", "modal_11_take_1", "modal_11_take_2", "modal_11_take_3"]
	# El identificador del rival lo reparte NetworkManager (los bots viven por
	# encima de los huecos de conexión), así que la clave del botón se compone
	# aquí en vez de darla por sabida.
	var rival_btn: String = "modal_11_target_%d" % NetworkManager.BOT_BASE_ID
	_steps = [
		Step.new(
			"Partida de práctica contra Ana, con las\ncartas puestas a propósito.\nHaz sólo lo que te marque y en un rato\nsabrás jugar."),

		# --- mirar las cartas ---
		Step.new(
			"Empiezas mirando 2 de tus 4 cartas.\nToca la PRIMERA por la izquierda.",
			"hand_0", ["hand_0"], "peek0"),
		Step.new(
			"Un 3: muy baja, te conviene guardarla.\nAhora toca la SEGUNDA.",
			"hand_1", ["hand_1"], "peek1"),
		Step.new(
			"El 12 de copas vale 30 PUNTOS: es la\npeor carta del juego. Los 12 de espadas\ny de oros, en cambio, valen 0.\nQuédate con que la tienes en 2ª posición."),
		Step.new(
			"No volverás a ver tus cartas en toda la\npartida. Pulsa \"Estoy listo\".",
			"ready_btn", ["ready_btn"], "playing"),

		# --- turno normal: robar y cambiar ---
		Step.new(
			"Es tu turno. Roba una carta del mazo.",
			"deck_btn", ["deck_btn"], "my_draw"),
		Step.new(
			"Un 1: la carta más baja que existe.\nCámbiala por tu SEGUNDA carta, el 12 de\ncopas que vale 30.",
			"hand_1", ["hand_1"], "gave_12"),

		# --- quemar ---
		Step.new(
			"Te has quitado 30 puntos de golpe.\nAhora juega Ana: mira qué descarta.",
			"discard", [], "ana_3", true),
		Step.new(
			"¡Un 3! Y tú sabes que tu primera carta\nes un 3. Cuando el número coincide\npuedes quemarla sin esperar tu turno.\nPulsa \"Quemar carta\".",
			"burn_btn", ["burn_btn", "discard"], "burn_modal"),
		Step.new(
			"Toca tu PRIMERA carta: es el 3.",
			"modal_burn_0", ["modal_burn_0"], "hand_of_3"),
		Step.new(
			"Quemada: esa carta ya no te suma nada.\nSi te equivocas de número te llevas una\ncarta de castigo, así que sólo se quema\ncuando te acuerdas de verdad."),
		Step.new(
			"El descarte queda QUEMADO: ya no se\npuede robar de él, sólo quemar encima."),

		# --- especial 1 de 3: el 10 ---
		Step.new(
			"Sigues tú. Roba del mazo.",
			"deck_btn", ["deck_btn"], "my_draw"),
		Step.new(
			"Un 10, la primera carta especial:\nal descartarlo puedes mirar UNA de tus\npropias cartas. Descártalo.",
			"drop_btn", ["drop_btn"], "special_10"),
		Step.new(
			"Elige la que quieras recordar.\nToca la TERCERA: es la que no conoces.",
			"modal_ten_2", ["modal_ten_2"], "ten_seen"),
		Step.new(
			"Ahí la tienes. Memorízala: te hará falta\npara quemar más adelante.",
			"modal_ten_ok", ["modal_ten_ok"], "no_special"),

		# --- especial 2 de 3: el 11 ---
		Step.new(
			"Turno de Ana otra vez.",
			"discard", [], "ana_6", true),
		Step.new(
			"Tu turno. Roba del mazo.",
			"deck_btn", ["deck_btn"], "my_draw"),
		Step.new(
			"Un 11, la segunda especial: obliga a un\nintercambio a ciegas. Descártalo.",
			"drop_btn", ["drop_btn"], "special_11"),
		Step.new(
			"Elige con quién intercambias.\nAquí sólo está Ana.",
			rival_btn, [rival_btn], "eleven_target"),
		Step.new(
			"Quédate con una carta de Ana.\nNo puedes verlas: elige a ciegas.",
			"modal_11_take_row", take_any, "eleven_slot"),
		Step.new(
			"Y ahora es Ana quien elige, también a\nciegas, cuál de tus cartas se lleva.\nTú NO decides qué le das: por eso el 11\nes la carta más incómoda del juego."),
		Step.new(
			"Mira el intercambio, y luego su turno.",
			"hand_row", [], "ana_7", true),
		Step.new(
			"Te has llevado una carta de Ana sin\nverla, y ella una tuya. Tu 2ª carta\nvuelve a ser un misterio."),

		# --- cantar Dutch ---
		Step.new(
			"Última lección. Desde la ronda 4 puedes\ncantar DUTCH al empezar tu turno.\nPúlsalo.",
			"dutch_btn", ["dutch_btn"], "dutch"),
		Step.new(
			"Cantar Dutch NO te salta el turno: lo\njuegas con normalidad. Después se da una\núltima vuelta a los demás y se cuentan\nlos puntos."),

		# --- especial 3 de 3: el 12 ---
		Step.new(
			"Pues juégalo: roba del mazo.",
			"deck_btn", ["deck_btn"], "my_draw"),
		Step.new(
			"El 12 de ESPADAS, la tercera especial.\nEspadas y oros valen 0; copas y bastos,\n30. Éste vale 0: quédatelo.\nCámbialo por tu 2ª carta, la que no\nconoces.",
			"hand_1", ["hand_1"], "got_0_points"),
		Step.new(
			"Has cambiado una carta desconocida por\nun 12 que vale 0. Ana juega su última\nvuelta y se cuentan los puntos.",
			"", [], "ended", true),
		Step.new(
			"Gana quien menos suma, y ahí lo tienes.\nRecordar tus cartas y quemar a tiempo\nes todo el secreto. ¡A jugar!"),
	]

## ---------- CONDICIONES ----------
##
## Todas se resuelven mirando el estado de verdad de la partida, nunca lo que se
## supone que el jugador ha pulsado. Así el guion no puede quedar desincronizado
## con la mesa.

func _step_done(cond: String) -> bool:
	match cond:
		"peek0": return _peeked(0)
		"peek1": return _peeked(1)
		"playing": return _status() == "playing"
		"my_draw": return _my_draw()
		"gave_12": return _top() == "copas-12"
		"ana_3": return _top() == "copas-3"
		"burn_modal": return _has_rect("modal_burn_0")
		"hand_of_3": return _my_hand().size() == 3
		"special_10": return str(_ps().get("type", "")) == "10"
		"ten_seen": return _ps().has("peeked_value")
		"no_special": return _ps().is_empty()
		"ana_6": return _top() == "bastos-6"
		"special_11": return str(_ps().get("type", "")) == "11"
		"eleven_target": return int(_ps().get("target_id", -1)) != -1
		"eleven_slot": return int(_ps().get("target_slot", -1)) != -1
		"ana_7": return _top() == "oros-7"
		"dutch": return int(GameLogic.state.get("dutch_caller_id", -1)) == NetworkManager.my_id
		"got_0_points": return _my_hand().has("espadas-12")
		"ended": return _status() == "ended"
	return false

## ---------- ESTADO DEL JUEGO ----------

func _status() -> String:
	return str(GameLogic.state.get("status", ""))

func _me() -> Dictionary:
	for p in GameLogic.state.get("players", []):
		if p.id == NetworkManager.my_id:
			return p
	return {}

func _my_hand() -> Array:
	return _me().get("hand", [])

func _peeked(i: int) -> bool:
	return _me().get("peeked_idx", []).has(i)

func _ps() -> Dictionary:
	return GameLogic.state.get("pending_special", {})

## Carta de arriba del descarte, que es lo que marca casi todas las lecciones.
func _top() -> String:
	var d: Array = GameLogic.state.get("discard", [])
	return str(d[-1]) if d.size() > 0 else ""

## ¿Tengo yo una carta robada pendiente de decidir?
func _my_draw() -> bool:
	var ad: Dictionary = GameLogic.state.get("active_draw", {})
	return not ad.is_empty() and ad.get("player_id", -1) == NetworkManager.my_id

## ¿Existe ya ese control en pantalla? Es la forma de saber que un modal se ha
## abierto sin tener que preguntárselo a la interfaz.
func _has_rect(key: String) -> bool:
	if not _rect_for.is_valid():
		return false
	return (_rect_for.call(key) as Rect2).size != Vector2.ZERO

## ---------- INTERFAZ ----------

func _build_ui() -> void:
	# ..._and_offsets_preset y NO set_anchors_preset: éste último recalcula los
	# desplazamientos para CONSERVAR el rectángulo actual, y como aquí se llama
	# después de add_child (cuando el nodo aún mide 0x0), la capa se quedaba de
	# tamaño cero para siempre. Con size en (0,0) el globo caía siempre arriba
	# a la izquierda y el foco salía como una banda horizontal absurda.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# La capa deja pasar los toques: quien decide qué se puede tocar es la
	# restricción que Main aplica a los controles de verdad, no un velo por
	# encima. Aquí sólo el globo de texto y sus botones reciben pulsaciones.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100

	_bubble = PanelContainer.new()
	var sb := DutchUI.box(DutchUI.PANEL_DEEP, DutchUI.GOLD, 2)
	DutchUI.shadowed(sb, 3, 0.6, Vector2(4, 4))
	_bubble.add_theme_stylebox_override("panel", sb)
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_bubble)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_bubble.add_child(col)

	_step_label = DutchUI.label("", 11, DutchUI.GOLD, true)
	col.add_child(_step_label)
	_text_label = DutchUI.label("", 15, DutchUI.TEXT, true)
	col.add_child(_text_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	var skip := DutchUI.button("Saltar tutorial", _finish)
	skip.custom_minimum_size = Vector2(150, 38)
	row.add_child(skip)
	_ok_btn = DutchUI.button("Vale", _advance, "primary")
	_ok_btn.custom_minimum_size = Vector2(120, 38)
	row.add_child(_ok_btn)

	_render_step()
	set_process(true)

func _render_step() -> void:
	var s: Step = _steps[_index]
	_step_label.text = "Paso %d de %d" % [_index + 1, _steps.size()]
	_text_label.text = s.text
	# Los pasos con condición se superan actuando en la mesa; el botón sólo
	# aparece en los informativos, para que nadie se los salte sin leerlos.
	_ok_btn.visible = s.done == ""
	if _index == _steps.size() - 1:
		_ok_btn.text = "¡A jugar!"
	if _set_gate.is_valid():
		_set_gate.call(s.gate)
	_reposition()

## El globo se coloca donde de verdad queda sitio: se mide el hueco libre por
## encima y por debajo del control señalado y se elige el que dé para el globo
## entero. Si no cabe en ninguno, se va al centro y se aparta en horizontal.
func _reposition() -> void:
	await get_tree().process_frame
	if not is_instance_valid(_bubble):
		return
	var s: Step = _steps[_index]
	var bs := _bubble.size
	var x: float = (size.x - bs.x) * 0.5

	# Con un modal abierto el globo se va ARRIBA, y Main baja el modal para
	# dejarle sitio: abajo taparía justo las cartas que hay que tocar.
	if s.target.begins_with("modal_"):
		_bubble.position = Vector2(x, 14.0)
		return

	var target := _target_rect()
	var y: float = size.y - bs.y - 14.0
	if target.size != Vector2.ZERO:
		var gap_top: float = target.position.y
		var gap_bottom: float = size.y - target.end.y
		if gap_bottom >= bs.y + 20.0:
			y = size.y - bs.y - 14.0
		elif gap_top >= bs.y + 20.0:
			y = 14.0
		else:
			y = (size.y - bs.y) * 0.5
		# Apartarse en horizontal del lado donde esté el control.
		if target.get_center().x > size.x * 0.6:
			x = min(x, target.position.x - bs.x - 14.0)
		elif target.get_center().x < size.x * 0.4:
			x = max(x, target.end.x + 14.0)

	_bubble.position = Vector2(clamp(x, 12.0, max(12.0, size.x - bs.x - 12.0)),
		clamp(y, 12.0, max(12.0, size.y - bs.y - 12.0)))

func _target_rect() -> Rect2:
	var s: Step = _steps[_index]
	if s.target == "" or not _rect_for.is_valid():
		return Rect2()
	var r: Rect2 = _rect_for.call(s.target)
	if r.size == Vector2.ZERO:
		return Rect2()
	# Los rectángulos llegan en coordenadas globales; esta capa cubre toda la
	# pantalla desde el origen, pero se resta por si acaso no lo está.
	return Rect2(r.position - get_global_rect().position, r.size)

func _advance() -> void:
	if _index >= _steps.size() - 1:
		_finish()
		return
	_index += 1
	Sfx.play("card")
	_render_step()

func _finish() -> void:
	if _aborted:
		return
	_aborted = true
	set_process(false)
	NetworkManager.tutorial_bots_paused = false
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 0), 0.2)
	tw.tween_callback(func():
		finished.emit()
		queue_free()
	)

## Cierre en seco, sin avisar a nadie: lo usa Main cuando el jugador vuelve al
## menú y la partida que este guion vigila deja de existir.
func abort() -> void:
	_aborted = true
	set_process(false)
	queue_free()

func _process(delta: float) -> void:
	if _aborted or GameLogic.state.is_empty():
		return
	_t += delta
	var s: Step = _steps[_index]
	# El rival sólo se mueve en los pasos que lo piden. Se reafirma cada
	# fotograma en vez de sólo al cambiar de paso, porque un descongelado que se
	# quedara pegado dejaría al rival jugando durante una explicación.
	NetworkManager.tutorial_bots_paused = not s.bots
	if s.done != "" and _step_done(s.done):
		_advance()
		return
	# Reposicionar en cada fotograma sería absurdo, pero la pantalla del juego
	# se reconstruye a cada cambio de estado y el control señalado se mueve,
	# así que el globo se recoloca de vez en cuando.
	if fmod(_t, 0.5) < delta:
		_reposition()
	queue_redraw()

## ---------- DIBUJO ----------
##
## SIN velo que oscurezca la pantalla. Un recorte rectangular alrededor de un
## botón que está pegado a otros le corta la mitad a los vecinos, y sobre este
## fondo de taberna quedaba sucio. Basta con un marco que late y una flecha que
## apunta: se ve igual de claro y no estropea el dibujo. Además ya no hace falta
## para dirigir la atención, porque el resto de la interfaz está desactivada.

func _draw() -> void:
	var target := _target_rect()
	if target.size == Vector2.ZERO:
		return

	var pulse: float = 0.5 + 0.5 * sin(_t * 4.0)
	var frame := target.grow(5.0)
	var col := Color(DutchUI.GOLD, 0.55 + 0.45 * pulse)
	var t := 3.0

	# Sombra del marco: lo despega del fondo sea del color que sea lo de abajo.
	var sh := Color(0, 0, 0, 0.5)
	_rect_frame(frame.grow(t), sh, t)
	_rect_frame(frame, col, t)

	# Flecha que señala desde el lado por el que está el globo, para que no
	# apunte desde detrás del propio texto.
	var from_bubble: Vector2 = _bubble.get_global_rect().get_center() - get_global_rect().position \
		if is_instance_valid(_bubble) else Vector2(size.x * 0.5, 0.0)
	var bob: float = 4.0 * sin(_t * 3.0)
	var d := from_bubble - frame.get_center()
	if abs(d.x) > abs(d.y):
		if d.x > 0.0:
			# El globo está a la derecha: la flecha apunta hacia la izquierda.
			_arrow(Vector2(frame.end.x + 6.0 + bob, frame.get_center().y), Vector2.LEFT, col)
		else:
			_arrow(Vector2(frame.position.x - 6.0 - bob, frame.get_center().y), Vector2.RIGHT, col)
	else:
		if d.y > 0.0:
			_arrow(Vector2(frame.get_center().x, frame.end.y + 6.0 + bob), Vector2.UP, col)
		else:
			_arrow(Vector2(frame.get_center().x, frame.position.y - 6.0 - bob), Vector2.DOWN, col)

func _rect_frame(r: Rect2, color: Color, t: float) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - t), Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(r.position, Vector2(t, r.size.y)), color, true)
	draw_rect(Rect2(Vector2(r.end.x - t, r.position.y), Vector2(t, r.size.y)), color, true)

## Flecha escalonada: filas de rectángulos en vez de un triángulo suave, para
## que sea del mismo material que el resto del pixel art.
func _arrow(tip: Vector2, dir: Vector2, color: Color) -> void:
	var u := 3.0
	var steps := 5
	for i in range(steps):
		var w := u
		var h := (i * 2.0 + 1.0) * u
		var pos := Vector2.ZERO
		if dir == Vector2.LEFT:
			pos = Vector2(tip.x + i * u, tip.y - h * 0.5)
			draw_rect(Rect2(pos, Vector2(w, h)), color, true)
		elif dir == Vector2.RIGHT:
			pos = Vector2(tip.x - i * u - u, tip.y - h * 0.5)
			draw_rect(Rect2(pos, Vector2(w, h)), color, true)
		elif dir == Vector2.UP:
			pos = Vector2(tip.x - h * 0.5, tip.y + i * u)
			draw_rect(Rect2(pos, Vector2(h, w)), color, true)
		else:
			pos = Vector2(tip.x - h * 0.5, tip.y - i * u - u)
			draw_rect(Rect2(pos, Vector2(h, w)), color, true)
