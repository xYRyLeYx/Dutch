extends Control
## Main.gd
##
## Interfaz del juego, construida por código y pensada para MÓVIL EN
## HORIZONTAL (960x540 de base). El reparto es el de una mesa real vista desde
## tu sitio: los rivales enfrente, los montones en el centro, tu mano delante
## y los botones a la derecha, donde cae el pulgar.
##
## Sobre las animaciones: cada pantalla se reconstruye entera cuando cambia el
## estado, así que los nodos no sobreviven de un render al siguiente y no se
## puede animar "el mismo" nodo moviéndose. En su lugar GameLogic marca en
## state.fx qué acaba de pasar, y aquí se recrea ese movimiento con una carta
## de atrezo que vuela por encima de todo (fx_layer) entre las posiciones
## reales de los nodos ya colocados. El destino se mantiene invisible hasta que
## la carta aterriza, así que parece un único movimiento continuo.

## Todos los tamaños son múltiplos exactos de la carta base de PixelArt
## (40x56). Si se usa cualquier otro, los píxeles salen de distinto tamaño y
## el pixel art se rompe.
const HAND_CARD := Vector2(80, 112)
const PILE_CARD := Vector2(80, 112)
const MINI_CARD := Vector2(40, 56)
const MODAL_CARD := Vector2(80, 112)
const SHOWCASE_CARD := Vector2(120, 168)

const SIDEBAR_W := 214

var table_color: ColorRect
var table: TextureRect
var content: VBoxContainer
var fx_layer: Control
var modal_layer: Control
var toast_box: PanelContainer
var toast_label: Label
var volume_widget: VolumeWidget

# Referencias vivas para que la cuenta atrás de quemar se actualice en su
# sitio SIN reconstruir la pantalla: rehacer el árbol en un temporizador se
# comía los clics, porque el botón recién creado sustituía al que estabas
# pulsando y se perdía el evento de soltar.
var _burn_label: Label = null
var _draw_deck_btn: Button = null
var _draw_discard_btn: Button = null
var _dutch_btn: Button = null
var _burn_btn: Button = null
var _discard_card: CardView = null
var _can_act_base: bool = false
var _discard_is_empty: bool = true
var _discard_burned: bool = false
var _deck_can_serve: bool = true
var _dutch_already_called: bool = false
var _dutch_round_locked: bool = true
var _pending_special_empty: bool = true

var _last_turn_id: int = -999
var _last_discard_top: String = ""
var _last_drawn_card: String = ""

var _anchors: Dictionary = {}
var _prev_rects: Dictionary = {}

# Restricción del tutorial guiado. Mientras está activa, de todos los controles
# registrados sólo responden los que el guion haya autorizado; el resto queda
# inerte. Se apoya en el MISMO registro de anclajes que las animaciones de
# cartas, así que no hay una segunda lista que mantener al día.
#
# _gate_base guarda, control por control, si la PARTIDA ya lo tenía apagado
# (no es tu turno, mazo agotado...). Sin eso, al cambiar de paso el tutorial no
# sabría distinguir "apagado por el guion" de "apagado por las reglas" y
# acabaría encendiendo botones que no debía.
var _gate: Array = []
var _gate_active: bool = false
var _gate_base: Dictionary = {}
var _tutorial: TutorialOverlay = null

# Contador de toques del acceso oculto a los ajustes de servidor.
var _secret_taps: int = 0
var _secret_last_tap_ms: int = 0

# Aviso de cuánta gente hay conectada, en el menú.
var _status_label: Label = null
var _pending_fx: Dictionary = {}
var _last_fx_seq: int = 0
var _hidden_by_fx: Array[Control] = []
var _peek_busy: bool = false
var _last_status: String = ""
var _end_sound_played: bool = false

# Menú animado: la capa de llamas y brasas, más las cosas que laten con la
# música (las cartas de portada y el título).
var bg_fx_layer: Control
var _menu_fx: MenuFx = null
var _menu_cards: Array[CardView] = []
var _menu_title: Label = null
var _anim_t: float = 0.0

func _ready() -> void:
	theme = DutchUI.build_theme()

	# El fondo va en dos capas y con nodos nativos, sin script propio. La capa
	# de color es el seguro: si por lo que sea la textura no llegara a
	# pintarse, lo que se ve detrás es madera oscura y no el gris del motor.
	table_color = ColorRect.new()
	table_color.color = PixelArt.WOOD_DARK
	table_color.set_anchors_preset(Control.PRESET_FULL_RECT)
	table_color.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(table_color)

	table = TextureRect.new()
	table.texture = PixelArt.tavern_background()
	table.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	table.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	table.stretch_mode = TextureRect.STRETCH_SCALE
	table.set_anchors_preset(Control.PRESET_FULL_RECT)
	table.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(table)

	# Entre el fondo y la interfaz: aquí viven las llamas y las brasas.
	bg_fx_layer = Control.new()
	bg_fx_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_fx_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg_fx_layer)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	fx_layer = Control.new()
	fx_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fx_layer)

	modal_layer = Control.new()
	modal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(modal_layer)

	_build_toast()

	# El mando de música va el ÚLTIMO de todos: así queda por encima incluso
	# de los modales oscurecidos y se puede tocar en cualquier momento, que es
	# justo lo que se espera de un control de volumen.
	volume_widget = VolumeWidget.new()
	volume_widget.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	volume_widget.offset_left = -(VolumeWidget.SIZE.x + 10.0)
	volume_widget.offset_top = 8.0
	volume_widget.offset_right = -10.0
	volume_widget.offset_bottom = 8.0 + VolumeWidget.SIZE.y
	add_child(volume_widget)

	NetworkManager.game_state_updated.connect(_render)
	NetworkManager.joined_as.connect(func(_id): _render())
	NetworkManager.connection_error.connect(_on_connection_error)
	# Mientras el relé no contesta no hay estado que dibujar, así que la sala de
	# espera se redibuja también cuando cambia el estado de la conexión; si no,
	# se quedaría en "Conectando..." aunque ya estuviera dentro.
	NetworkManager.status_updated.connect(func(_info): _render_status())
	NetworkManager.connection_changed.connect(func():
		if NetworkManager.online and GameLogic.state.is_empty():
			_show_lobby())

	# Mientras se está en el menú, el juego pregunta cuánta gente hay (y de paso
	# avisa de que él está ahí). Sólo corre en el menú: dentro de una partida ya
	# hay conexión, y así el servidor gratuito puede dormirse cuando no queda
	# nadie.
	#
	# Cada 10 s y no cada 30: medio minuto mirando un número que no se mueve
	# parece que esté roto, y el jugador acaba tocándolo para comprobar que va.
	# El gasto es el mismo en la práctica —lo que mantiene despierto al servidor
	# es que haya alguien preguntando, no cada cuánto lo haga—, así que más vale
	# que la cifra sea fresca.
	var presence_timer := Timer.new()
	presence_timer.wait_time = 10.0
	presence_timer.autostart = true
	add_child(presence_timer)
	presence_timer.timeout.connect(func():
		if is_instance_valid(_status_label):
			NetworkManager.fetch_status())

	var ticker := Timer.new()
	ticker.wait_time = 0.08
	ticker.autostart = true
	add_child(ticker)
	ticker.timeout.connect(_tick_burn_countdown)

	_show_home()

## ---------- UTILIDADES ----------

## Los menús enseñan el interior de la taberna (pared de piedra, antorchas,
## estandarte); la partida enseña el tablero de la mesa visto desde arriba,
## que es mucho más sobrio para no pelearse con las cartas.
func _set_bg(interior: bool) -> void:
	if not is_instance_valid(table):
		return
	table.texture = PixelArt.tavern_scene() if interior else PixelArt.tavern_background()
	# Las llamas sólo existen en los menús: durante la partida estorbarían y
	# además la mesa no tiene antorchas.
	if interior:
		if _menu_fx == null or not is_instance_valid(_menu_fx):
			_menu_fx = MenuFx.new()
			# Los anclajes se fijan ANTES de meterlo en el árbol, igual que el
			# resto de capas: es el orden que ya se sabe que funciona aquí.
			_menu_fx.set_anchors_preset(Control.PRESET_FULL_RECT)
			bg_fx_layer.add_child(_menu_fx)
		Music.play_for("menu")
	else:
		if is_instance_valid(_menu_fx):
			_menu_fx.queue_free()
		_menu_fx = null
		Music.play_for("game")
	_menu_cards.clear()
	_menu_title = null

## Late todo lo del menú al compás de la música. Sólo corre mientras la capa
## de efectos existe, así que durante la partida esto no cuesta nada.
func _process(delta: float) -> void:
	if not is_instance_valid(_menu_fx):
		return
	_anim_t += delta
	var beat: float = Music.beat()
	for i in range(_menu_cards.size()):
		var cv: CardView = _menu_cards[i]
		if not is_instance_valid(cv):
			continue
		# Balanceo lento y continuo, más un empujón con cada golpe grave. Las
		# tres cartas van desfasadas para que la portada no "salte" en bloque.
		cv.set_lift(sin(_anim_t * 1.5 + i * 1.1) * 3.0 + beat * 6.0)
	if is_instance_valid(_menu_title):
		var s: float = 1.0 + beat * 0.07
		_menu_title.pivot_offset = _menu_title.size * 0.5
		_menu_title.scale = Vector2(s, s)

func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

func _title(text: String, size: int = 30) -> Label:
	return DutchUI.title(text, size)

func _label(text: String, size: int = 14, color: Color = DutchUI.TEXT, center: bool = false) -> Label:
	return DutchUI.label(text, size, color, center)

func _para(text: String, size: int = 13, color: Color = DutchUI.TEXT_MUTED) -> Label:
	return DutchUI.paragraph(text, size, color)

func _btn(text: String, cb: Callable, primary: bool = false) -> Button:
	return DutchUI.button(text, cb, "primary" if primary else "ghost")

func _panel(highlight: bool = false) -> PanelContainer:
	return DutchUI.panel(highlight)

func _card(s: Vector2 = HAND_CARD) -> CardView:
	var c := CardView.new()
	c.custom_minimum_size = s
	c.pivot_offset = s * 0.5
	return c

func _mini_card() -> CardView:
	var c := _card(MINI_CARD)
	c.set_interactive(false)
	return c

func _spacer(min_size: float = 0.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(min_size, min_size)
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

## Hueco de ancho fijo que no se estira. Se usa para reservarle sitio al mando
## de música, que flota anclado a la esquina y no participa del reparto.
func _gap(w: float, h: float = 0.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

func _row(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", sep)
	return h

func _col(sep: int = 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", sep)
	return v

## Ficha cuadrada con la inicial: identifica a cada jugador sin necesitar
## avatares. Cuadrada, no redonda, porque un círculo suavizado desentonaría
## con el resto del pixel art.
func _avatar(player_name: String, active: bool, s: float = 26.0) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := DutchUI.box(DutchUI.GOLD if active else DutchUI.PANEL_DEEP, DutchUI.GOLD_DARK if active else DutchUI.PANEL_BORDER, 2)
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(s, s)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var initial := player_name.substr(0, 1).to_upper() if player_name.length() > 0 else "?"
	var l := DutchUI.title(initial, int(s * 0.55), DutchUI.TEXT_DARK if active else DutchUI.GOLD)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p

## ---------- AVISOS ----------

func _build_toast() -> void:
	toast_box = PanelContainer.new()
	var sb := DutchUI.box(DutchUI.PANEL_DEEP, DutchUI.GOLD, 2)
	DutchUI.shadowed(sb, 2, 0.6, Vector2(3, 3))
	toast_box.add_theme_stylebox_override("panel", sb)
	toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_box.modulate = Color(1, 1, 1, 0)
	toast_label = DutchUI.label("", 14, DutchUI.TEXT, true)
	toast_box.add_child(toast_label)
	add_child(toast_box)

func _toast(msg: String) -> void:
	print("[Dutch] ", msg)
	if not is_instance_valid(toast_box):
		return
	toast_label.text = msg
	toast_box.modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.tween_property(toast_box, "modulate", Color(1, 1, 1, 1), 0.15)
	tw.tween_interval(2.0)
	tw.tween_property(toast_box, "modulate", Color(1, 1, 1, 0), 0.35)

## ---------- ANIMACIONES BÁSICAS ----------

func _animate_card_in(cv: CardView) -> void:
	cv.scale = Vector2(0.7, 0.7)
	cv.modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(cv, "scale", Vector2.ONE, 0.24)
	tw.parallel().tween_property(cv, "modulate", Color(1, 1, 1, 1), 0.16)

func _animate_fade_in(ctrl: CanvasItem) -> void:
	ctrl.modulate = Color(1, 1, 1, 0)
	create_tween().tween_property(ctrl, "modulate", Color(1, 1, 1, 1), 0.22)

## El pivote se fija tras el primer layout: antes de eso el nodo no tiene
## tamaño y escalaría desde la esquina en vez de desde su centro.
func _animate_pop(ctrl: Control) -> void:
	ctrl.modulate = Color(1, 1, 1, 0)
	await get_tree().process_frame
	if not is_instance_valid(ctrl):
		return
	ctrl.pivot_offset = ctrl.size * 0.5
	ctrl.scale = Vector2(0.94, 0.94)
	var tw := create_tween()
	tw.tween_property(ctrl, "modulate", Color(1, 1, 1, 1), 0.18)
	tw.parallel().tween_property(ctrl, "scale", Vector2.ONE, 0.26) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## ---------- VUELOS DE CARTA ----------

func _register(key: String, node: Control) -> void:
	_anchors[key] = node
	if node is Button:
		_gate_base[key] = (node as Button).disabled

## Los anclajes se rehacen enteros en cada render, y con ellos la foto de qué
## controles venían ya apagados.
func _clear_anchors() -> void:
	_anchors.clear()
	_gate_base.clear()

## ---------- RESTRICCIÓN DEL TUTORIAL ----------

## Deja activos SÓLO los controles cuya clave esté en `keys`. Lo llama el guion
## en cada paso.
func set_input_gate(keys: Array) -> void:
	_gate = keys
	_gate_active = true
	_apply_gate()

func clear_input_gate() -> void:
	_gate = []
	_gate_active = false
	for key in _anchors.keys():
		var n: Variant = _anchors[key]
		if is_instance_valid(n) and n is CardView:
			(n as CardView).set_locked(false)
	_tick_burn_countdown()

func _gate_allows(key: String) -> bool:
	return (not _gate_active) or _gate.has(key)

## Se llama al final de cada pantalla y cada vez que el guion cambia de paso.
## Las cartas se bloquean con `locked` (que no toca `interactive`, para no
## borrar lo que la partida decidió) y los botones combinan su estado de
## partida con el permiso del guion.
func _apply_gate() -> void:
	if not _gate_active:
		return
	for key in _anchors.keys():
		var n: Variant = _anchors[key]
		if not is_instance_valid(n):
			continue
		var allowed: bool = _gate.has(str(key))
		if n is CardView:
			(n as CardView).set_locked(not allowed)
		elif n is Button:
			(n as Button).disabled = bool(_gate_base.get(key, false)) or not allowed
	_tick_burn_countdown()

func _rect_of(key: String) -> Rect2:
	var node: Variant = _anchors.get(key)
	if node == null or not is_instance_valid(node):
		return Rect2()
	var c := node as Control
	if c.size == Vector2.ZERO:
		return Rect2()
	return c.get_global_rect()

## Igual que _rect_of pero cayendo en la foto del render anterior. Hace falta
## para los movimientos cuyo ORIGEN ya no existe en la pantalla nueva: al
## descartar la robada, su hueco desaparece en el mismo render en el que hay
## que animar la carta saliendo de él.
func _rect_or_prev(key: String) -> Rect2:
	var r := _rect_of(key)
	if r.size != Vector2.ZERO:
		return r
	return _prev_rects.get(key, Rect2())

func _snapshot_rects() -> void:
	_prev_rects.clear()
	for key in _anchors.keys():
		var r := _rect_of(key)
		if r.size != Vector2.ZERO:
			_prev_rects[key] = r

func _card_rect_at(center: Vector2, card_size: Vector2) -> Rect2:
	return Rect2(center - card_size * 0.5, card_size)

func _player_anchor(player_id: int, slot: int) -> Rect2:
	if player_id == NetworkManager.my_id:
		var r := _rect_of("hand_%d" % slot)
		if r.size != Vector2.ZERO:
			return r
		r = _rect_of("hand_0")
		if r.size != Vector2.ZERO:
			return r
		r = _rect_of("hand_row")
		if r.size != Vector2.ZERO:
			return _card_rect_at(r.get_center(), HAND_CARD)
		return Rect2()
	var mini := _rect_of("mini_%d_%d" % [player_id, slot])
	if mini.size != Vector2.ZERO:
		return mini
	var seat := _rect_of("seat_%d" % player_id)
	if seat.size != Vector2.ZERO:
		return _card_rect_at(seat.get_center(), MINI_CARD)
	return Rect2()

func _fly(card_id: String, face_up: bool, from: Rect2, to: Rect2, opts: Dictionary = {}) -> void:
	if from.size == Vector2.ZERO or to.size == Vector2.ZERO:
		return
	var dur: float = opts.get("dur", 0.38)
	var delay: float = opts.get("delay", 0.0)
	var arc: float = opts.get("arc", 34.0)
	var spin: float = opts.get("spin", 0.0)
	var flip_at: float = opts.get("flip_at", -1.0)
	var on_done: Callable = opts.get("on_done", Callable())

	var origin := fx_layer.get_global_rect().position
	var from_pos := from.position - origin
	var to_pos := to.position - origin

	var cv := CardView.new()
	cv.set_interactive(false)
	cv.custom_minimum_size = Vector2.ZERO
	cv.size = from.size
	cv.position = from_pos
	cv.pivot_offset = from.size * 0.5
	if flip_at >= 0.0 or not face_up or card_id == "":
		cv.set_back()
	else:
		cv.set_card(card_id, true)
	fx_layer.add_child(cv)

	# Envuelto en un array porque los lambdas capturan por valor: el "ya he
	# volteado" tiene que sobrevivir entre llamadas del tween.
	var flipped := [false]
	var tw := cv.create_tween()
	if delay > 0.0:
		cv.modulate = Color(1, 1, 1, 0)
		tw.tween_property(cv, "modulate", Color(1, 1, 1, 1), 0.01).set_delay(delay)
	tw.tween_method(func(t: float):
		if not is_instance_valid(cv):
			return
		var e: float = t * t * (3.0 - 2.0 * t)
		cv.size = from.size.lerp(to.size, e)
		cv.pivot_offset = cv.size * 0.5
		cv.position = from_pos.lerp(to_pos, e) + Vector2(0, -arc * sin(PI * e))
		cv.rotation = deg_to_rad(spin * sin(PI * e))
		if flip_at >= 0.0 and not flipped[0] and e >= flip_at:
			flipped[0] = true
			cv.flip_to(card_id, face_up)
	, 0.0, 1.0, dur)
	tw.tween_callback(func():
		if on_done.is_valid():
			on_done.call()
		if is_instance_valid(cv):
			cv.queue_free()
	)

func _hide_until_landing(ctrl: Control) -> void:
	if ctrl == null or not is_instance_valid(ctrl):
		return
	ctrl.modulate = Color(1, 1, 1, 0)
	_hidden_by_fx.append(ctrl)

func _reveal_landed() -> void:
	for c in _hidden_by_fx:
		if is_instance_valid(c):
			c.modulate = Color(1, 1, 1, 1)
			if c is CardView:
				_animate_card_in(c)
	_hidden_by_fx.clear()

func _flush_fx() -> void:
	var fx := _pending_fx
	_pending_fx = {}
	# Dos frames: uno para que los contenedores ordenen a sus hijos y otro
	# para que las posiciones que leemos sean ya las definitivas.
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	if fx.is_empty():
		_snapshot_rects()
		_reveal_landed()
		return
	_run_fx(fx)
	# La foto se toma DESPUÉS de lanzar los vuelos: mientras _run_fx corre,
	# _prev_rects todavía tiene que describir la pantalla anterior.
	_snapshot_rects()
	await get_tree().create_timer(0.9).timeout
	_reveal_landed()

## Devuelve el "al aterrizar" de un vuelo: suena el golpe justo cuando la
## carta toca la mesa, no cuando sale. Es la diferencia entre que el sonido
## acompañe al movimiento o vaya por su cuenta.
func _landed(sound: String, smoke: bool = false) -> Callable:
	return func():
		if sound != "":
			Sfx.play(sound)
		if smoke:
			_spawn_smoke(_rect_of("discard"))
		_reveal_landed()

## Humareda sobre una carta recién quemada.
func _spawn_smoke(global_rect: Rect2) -> void:
	if global_rect.size == Vector2.ZERO:
		return
	var origin := fx_layer.get_global_rect().position
	var fx := SmokeFx.new()
	fx_layer.add_child(fx)
	# El grano del humo se saca del tamaño de la carta, para que sus píxeles
	# midan lo mismo que los de la carta que está ardiendo.
	fx.setup(Rect2(global_rect.position - origin, global_rect.size),
		max(2.0, floor(global_rect.size.y / float(PixelArt.H))))

func _run_fx(fx: Dictionary) -> void:
	var kind: String = fx.get("kind", "")
	var me: int = NetworkManager.my_id
	match kind:
		"draw":
			var actor: int = int(fx.get("actor", -1))
			var from := _rect_of("deck") if fx.get("source", "deck") == "deck" else _rect_of("discard")
			var to := _rect_of("drawn") if actor == me else _player_anchor(actor, 0)
			var card: String = GameLogic.state.get("active_draw", {}).get("card", "")
			# Sólo yo veo el valor de mi carta robada; la de un rival vuela
			# boca abajo, igual que en la mesa.
			var show_face: bool = actor == me and card != ""
			if bool(fx.get("reshuffled", false)):
				Sfx.play("shuffle", 0.0)
				_announce("Se barajó el descarte\npara formar un mazo nuevo")
			Sfx.play("draw")
			_fly(card, show_face, from, to, {
				"dur": 0.34,
				"spin": 5.0,
				"flip_at": 0.45 if show_face else -1.0,
				"on_done": _landed(""),
			})
		"discard", "burn_ok":
			var actor2: int = int(fx.get("actor", -1))
			var card2: String = fx.get("card", "")
			var slot: int = int(fx.get("slot", 0))
			var from2 := _rect_or_prev("drawn") if fx.get("from", "") == "drawn" else _player_anchor(actor2, slot)
			if from2.size == Vector2.ZERO:
				from2 = _player_anchor(actor2, slot)
			# La quemada suena a fogonazo al llegar; un descarte normal, a
			# carta que se posa.
			_fly(card2, true, from2, _rect_of("discard"), {
				"dur": 0.36,
				"spin": 8.0,
				"flip_at": 0.4,
				"on_done": _landed("burn" if kind == "burn_ok" else "place", kind == "burn_ok"),
			})
		"swap":
			# Dos movimientos a la vez: la robada entra en la mano y la vieja
			# sale al descarte. Verlo así es lo que explica el intercambio.
			var actor3: int = int(fx.get("actor", -1))
			var slot3: int = int(fx.get("slot", 0))
			var hand_rect := _player_anchor(actor3, slot3)
			var drawn_rect := _rect_or_prev("drawn")
			if drawn_rect.size == Vector2.ZERO:
				drawn_rect = _rect_of("deck")
			Sfx.play("draw")
			_fly("", false, drawn_rect, hand_rect, {"dur": 0.30, "arc": 24.0, "spin": -6.0})
			_fly(fx.get("card", ""), true, hand_rect, _rect_of("discard"), {
				"dur": 0.38,
				"delay": 0.10,
				"spin": 10.0,
				"flip_at": 0.35,
				"on_done": _landed("place"),
			})
		"burn_fail":
			var actor4: int = int(fx.get("actor", -1))
			Sfx.play("burn_fail")
			_fly("", false, _rect_of("deck"), _player_anchor(actor4, 99), {"dur": 0.36, "spin": -8.0})
			if actor4 == me:
				_toast("¡Fallaste al quemar! Te llevas una carta de penalización.")
				_shake_hand()
		"swap11":
			var a: int = int(fx.get("a", -1))
			var b: int = int(fx.get("b", -1))
			var ra := _player_anchor(a, int(fx.get("a_slot", 0)))
			var rb := _player_anchor(b, int(fx.get("b_slot", 0)))
			Sfx.play("swap")
			_fly("", false, ra, rb, {"dur": 0.5, "arc": 44.0, "spin": 12.0})
			_fly("", false, rb, ra, {"dur": 0.5, "arc": -44.0, "spin": -12.0})
		"dutch":
			Sfx.play("dutch", 0.0)
			_flourish("DUTCH")
			if int(fx.get("actor", -1)) == me:
				_toast("Has dicho DUTCH. Ahora juega tu turno con normalidad.")
		_:
			_reveal_landed()

func _shake_hand() -> void:
	for key in _anchors.keys():
		if str(key).begins_with("hand_"):
			var n: Variant = _anchors[key]
			if is_instance_valid(n) and n is CardView:
				(n as CardView).shake()

## Cartel a media pantalla para los avisos que TODOS tienen que ver, aunque no
## estén mirando el registro lateral. A diferencia de _flourish, éste lleva
## panel detrás y tipografía más contenida, porque son frases y no una palabra.
func _announce(text: String) -> void:
	var panel := _panel(true)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := _col(2)
	box.add_child(DutchUI.title(text, 26))
	panel.add_child(box)
	fx_layer.add_child(panel)
	panel.position = Vector2(size.x * 0.5, size.y * 0.40)
	panel.modulate = Color(1, 1, 1, 0)
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	# El centrado se hace tras el primer layout: hasta entonces el panel no
	# sabe lo ancho que es su propio texto.
	panel.pivot_offset = panel.size * 0.5
	panel.position = (size - panel.size) * 0.5 - Vector2(0, size.y * 0.06)
	panel.scale = Vector2(0.85, 0.85)
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate", Color(1, 1, 1, 1), 0.18)
	tw.parallel().tween_property(panel, "scale", Vector2.ONE, 0.3) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.8)
	tw.tween_property(panel, "modulate", Color(1, 1, 1, 0), 0.4)
	tw.tween_callback(panel.queue_free)

func _flourish(text: String) -> void:
	var l := DutchUI.title(text, 64, DutchUI.GOLD)
	l.size = Vector2(500, 90)
	l.position = Vector2(size.x * 0.5 - 250, size.y * 0.4)
	l.pivot_offset = Vector2(250, 45)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.scale = Vector2(0.4, 0.4)
	l.modulate = Color(1, 1, 1, 0)
	fx_layer.add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "modulate", Color(1, 1, 1, 1), 0.18)
	tw.tween_interval(0.7)
	tw.tween_property(l, "modulate", Color(1, 1, 1, 0), 0.3)
	tw.parallel().tween_property(l, "scale", Vector2(1.3, 1.3), 0.3)
	tw.tween_callback(l.queue_free)

## ---------- CUENTA ATRÁS DE QUEMAR ----------

func _tick_burn_countdown() -> void:
	if GameLogic.state.get("status", "") != "playing":
		return
	var burn_active: bool = GameLogic.burn_window_active() and _pending_special_empty
	var remaining: float = GameLogic.burn_window_remaining_ms() / 1000.0

	if is_instance_valid(_burn_label):
		_burn_label.text = "¡Todos pueden quemar!  %.1fs" % remaining
		_burn_label.visible = burn_active

	if is_instance_valid(_discard_card):
		if burn_active:
			_discard_card.set_progress(clamp(remaining / max(0.1, GameLogic.burn_window_ms / 1000.0), 0.0, 1.0))
		elif _discard_card.timer_progress >= 0.0:
			# Sólo en la transición: apagar el halo en cada tick mataría y
			# recrearía el tween doce veces por segundo.
			_discard_card.set_progress(-1.0)
			_discard_card.pulse(false)

	var can_act: bool = _can_act_base and not burn_active

	# Cuando te toca y lo único que te frena es la ventana de quemar, el botón
	# lo dice: un botón gris es idéntico a "no es tu turno" y parece que el
	# juego se ha colgado en vez de que faltan unos segundos.
	var waiting: bool = _can_act_base and burn_active
	if is_instance_valid(_draw_deck_btn):
		# Si el mazo está seco y el descarte no da para rehacerlo, el botón no
		# puede servir nada: se apaga y lo dice, en vez de quedarse activo sin
		# hacer nada al pulsarlo.
		# El permiso del tutorial se suma aquí y no sólo al construir la pantalla:
		# este tic reescribe `disabled` doce veces por segundo, así que sin el
		# término del guion volvería a encender lo que el guion había apagado.
		_draw_deck_btn.disabled = not can_act or not _deck_can_serve or not _gate_allows("deck_btn")
		if not _deck_can_serve:
			_draw_deck_btn.text = "Mazo agotado"
		else:
			_draw_deck_btn.text = ("Espera %.1fs" % remaining) if waiting else "Robar del mazo"
	if is_instance_valid(_draw_discard_btn):
		_draw_discard_btn.disabled = not can_act or _discard_is_empty or _discard_burned or not _gate_allows("discard_btn")
		if _discard_burned:
			_draw_discard_btn.text = "Descarte quemado"
		else:
			_draw_discard_btn.text = ("Espera %.1fs" % remaining) if waiting else "Robar del descarte"
	if is_instance_valid(_dutch_btn):
		_dutch_btn.disabled = not can_act or _dutch_already_called or _dutch_round_locked or not _gate_allows("dutch_btn")

## ---------- INICIO ----------

func _show_home() -> void:
	_clear(content)
	_close_modal()
	_pending_fx = {}
	_set_bg(true)

	var main := _row(30)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(main)

	# Izquierda: tres cartas en abanico a modo de portada.
	var left := _col(10)
	main.add_child(left)
	_menu_title = _title("DUTCH", 44)
	left.add_child(_menu_title)
	var showcase := CardFan.new()
	showcase.card_size = SHOWCASE_CARD
	showcase.gap = -28.0
	showcase.max_angle_deg = 20.0
	# arc_lift a 0: aquí la elevación la lleva la música, y si el abanico
	# también levantase la carta central se sumarían los dos movimientos.
	showcase.arc_lift = 0.0
	showcase.custom_minimum_size = Vector2(300, SHOWCASE_CARD.y + 24)
	left.add_child(showcase)
	for id in ["copas-12", "oros-11", "espadas-10"]:
		var c := _card(SHOWCASE_CARD)
		c.set_interactive(false)
		c.set_card(id, true)
		showcase.add_child(c)
		_menu_cards.append(c)
	left.add_child(_secret_zone("Baraja española · 4 cartas · gana quien menos suma"))

	# Derecha: nombre y botones.
	var right := _col(8)
	right.custom_minimum_size = Vector2(300, 0)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	main.add_child(right)

	var name_input := LineEdit.new()
	name_input.placeholder_text = "Tu nombre"
	name_input.custom_minimum_size = Vector2(0, 42)
	right.add_child(name_input)

	right.add_child(_btn("Jugar contra bots", func():
		if not _name_ok(name_input): return
		NetworkManager.start_local_game(name_input.text.strip_edges())
	, true))

	# Con desconocidos: un solo botón y sin listas. Con pocos jugadores una
	# lista de salas estaría casi siempre vacía y daría sensación de juego
	# muerto; así, si no hay mesa abierta, abres tú una y esperas dentro.
	right.add_child(_btn("Buscar partida pública", func():
		if not _name_ok(name_input): return
		NetworkManager.find_public_game(name_input.text.strip_edges())
		if NetworkManager.online:
			_show_lobby()
	))

	# Cuánta gente hay, justo debajo del botón: es donde hace falta decidir si
	# esperas o te vas con los bots. Se toca para volver a mirar.
	_status_label = _label("", 12, DutchUI.TEXT_MUTED, true)
	_status_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_status_label.gui_input.connect(_on_status_tap)
	right.add_child(_status_label)
	_render_status()
	NetworkManager.fetch_status()

	right.add_child(_btn("Crear partida privada", func():
		if not _name_ok(name_input): return
		NetworkManager.host_game(name_input.text.strip_edges(), false)
		# Sólo se entra a la sala si la conexión ha arrancado: si algo falló,
		# host_game ya ha avisado y no hay nada que enseñar.
		if NetworkManager.online:
			_show_lobby()
	))

	var code_input := LineEdit.new()
	code_input.placeholder_text = "Código de un amigo"
	code_input.max_length = 4
	code_input.custom_minimum_size = Vector2(0, 42)
	right.add_child(code_input)

	right.add_child(_btn("Unirme con código", func():
		if not _name_ok(name_input): return
		if code_input.text.strip_edges().length() < 4:
			_toast("Escribe el código de la sala")
			return
		NetworkManager.join_game(code_input.text.strip_edges(), name_input.text.strip_edges())
		if NetworkManager.online:
			_show_lobby()
	))

	# Hueco FIJO, no elástico: con un separador que se expande, la columna
	# empuja estos dos botones hasta el borde inferior y quedan descolgados del
	# resto del menú.
	right.add_child(_gap(0, 6))
	var help_row := _row(8)
	right.add_child(help_row)
	var tutorial_btn := _btn("Tutorial", func(): _start_tutorial(name_input.text.strip_edges()))
	tutorial_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_row.add_child(tutorial_btn)
	var rules_btn := _btn("Reglas", func(): _open_rules())
	rules_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_row.add_child(rules_btn)

## ---------- CUÁNTA GENTE HAY ----------

func _on_status_tap(event: InputEvent) -> void:
	var tapped := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		tapped = true
	elif event is InputEventScreenTouch and not event.pressed:
		tapped = true
	if tapped:
		NetworkManager.fetch_status()
		_render_status(true)

## El texto se elige para que SIEMPRE diga qué hacer a continuación. "0
## jugadores conectados" a secas desanima; "no hay nadie, juega contra bots o
## abre mesa" es la misma información y además resuelve.
func _render_status(recargando: bool = false) -> void:
	if not is_instance_valid(_status_label):
		return
	var info: Dictionary = NetworkManager.last_status
	if recargando or info.is_empty():
		_status_label.text = "Mirando cuánta gente hay..."
		_status_label.add_theme_color_override("font_color", DutchUI.TEXT_MUTED)
		return
	if bool(info.get("error", false)):
		_status_label.text = "No se pudo saber cuánta gente hay (toca para reintentar)"
		_status_label.add_theme_color_override("font_color", DutchUI.TEXT_MUTED)
		return
	var mesas: int = int(info.get("mesas_abiertas", 0))
	var jugando: int = int(info.get("jugando", 0))
	# Cuánta gente tiene el juego abierto, esté donde esté. Los servidores
	# antiguos no mandan este dato: se recurre a los conectados para que una
	# versión vieja del relé no deje la línea en blanco.
	var gente: int = int(info.get("en_la_app", info.get("conectados", 0)))
	# Uno mismo también cuenta, y decir "1 jugador conectado" cuando ese uno
	# eres tú suena a tomadura de pelo.
	var otros: int = max(0, gente - 1)

	var linea1 := ""
	if otros <= 0:
		linea1 = "No hay nadie más con el juego abierto"
	elif otros == 1:
		linea1 = "1 jugador más con el juego abierto"
	else:
		linea1 = "%d jugadores con el juego abierto" % otros
	if jugando > 0:
		linea1 += " (%d jugando)" % jugando

	var linea2 := ""
	var color := DutchUI.TEXT_MUTED
	if mesas > 0:
		color = DutchUI.GOLD
		linea2 = "Hay %d mesa%s esperando gente. ¡Entra!" % [mesas, "" if mesas == 1 else "s"]
	elif otros > 0:
		linea2 = "Ninguna mesa abierta: crea una y te verán."
	else:
		linea2 = "Juega contra bots o avisa a un amigo."

	_status_label.text = linea1 + "
" + linea2
	_status_label.add_theme_color_override("font_color", color)
	# Un parpadeo suave en cada actualización. Sin él, un dato que no cambia no
	# se distingue de un dato congelado, y era justo lo que hacía dudar de si
	# aquello se refrescaba solo.
	_status_label.modulate = Color(1, 1, 1, 0.3)
	_status_label.create_tween().tween_property(_status_label, "modulate", Color(1, 1, 1, 1), 0.5)

## Sin nombre no se juega a nada: aparece en la mesa de los demás.
func _name_ok(field: LineEdit) -> bool:
	if field.text.strip_edges() != "":
		return true
	_toast("Escribe tu nombre primero")
	return false

## Un fallo de conexión no puede dejarte mirando una sala de espera que ya no
## existe: se avisa y se vuelve al menú.
func _on_connection_error(msg: String) -> void:
	_toast(msg)
	if not NetworkManager.online and GameLogic.state.is_empty():
		_back_to_menu()

## Acceso OCULTO a los ajustes de servidor: cinco toques seguidos en la línea
## pequeña de la portada.
##
## No hay botón a la vista a propósito. A un jugador normal la palabra
## "servidor" sólo le desconcierta —el juego ya trae la dirección puesta y no
## tiene que tocar nada—, pero si algún día el relé se muda de sitio hace falta
## alguna manera de cambiarlo sin publicar una actualización.
func _secret_zone(text: String) -> Label:
	var l := _label(text, 12, DutchUI.TEXT_MUTED, true)
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.gui_input.connect(_on_secret_input)
	return l

func _on_secret_input(event: InputEvent) -> void:
	var tapped := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		tapped = true
	elif event is InputEventScreenTouch and not event.pressed:
		tapped = true
	if not tapped:
		return
	var now := Time.get_ticks_msec()
	# Los toques tienen que ir seguidos: espaciados, el contador se reinicia.
	# Así nadie acaba aquí por tocar la pantalla sin querer.
	_secret_taps = (_secret_taps + 1) if now - _secret_last_tap_ms < 900 else 1
	_secret_last_tap_ms = now
	if _secret_taps >= 5:
		_secret_taps = 0
		Sfx.play("chime", 0.0)
		_open_server_modal()

## Dónde vive el relé. Se llega por el acceso oculto de arriba. Queda guardado
## en el aparato, así que cambiar de servidor NO obliga a reinstalar el juego.
func _open_server_modal() -> void:
	var inner := _modal_box()
	inner.add_child(DutchUI.title("Servidor de partidas", 24))
	inner.add_child(_para("Dirección del relé que junta a los jugadores. La misma para todos los que quieran jugar juntos.", 12))

	var url_input := LineEdit.new()
	url_input.text = NetworkManager.relay_url
	url_input.placeholder_text = "wss://mi-servidor-de-dutch.onrender.com"
	url_input.custom_minimum_size = Vector2(520, 42)
	inner.add_child(url_input)
	inner.add_child(_label("Empieza por wss:// (o ws:// si es en tu propia red)", 11, DutchUI.TEXT_MUTED, true))

	var row := _row(10)
	inner.add_child(row)
	var save := _btn("Guardar", func():
		var url := url_input.text.strip_edges()
		if not (url.begins_with("ws://") or url.begins_with("wss://")):
			_toast("La dirección debe empezar por wss:// o ws://")
			return
		NetworkManager.set_relay_url(url)
		_close_modal()
		_toast("Servidor guardado")
	, true)
	save.custom_minimum_size = Vector2(180, 44)
	row.add_child(save)
	var cancel := _btn("Cancelar", func(): _close_modal())
	cancel.custom_minimum_size = Vector2(150, 44)
	row.add_child(cancel)

## Reglas en texto, paso a paso. Se añade como hijo directo de Main (no a
## modal_layer), así que se puede abrir desde cualquier pantalla —incluida una
## partida en curso— sin pelearse con los modales del juego.
func _open_rules() -> void:
	var rules := RulesScreen.new()
	add_child(rules)
	rules.setup()

## Tutorial guiado: una partida de verdad, pero con las cartas colocadas a
## propósito y un guion encima que señala el control que toca y desactiva todo
## lo demás. Se aprende jugando, no leyendo, y no hay forma de salirse del guion
## y quedarse perdido.
func _start_tutorial(player_name: String) -> void:
	if is_instance_valid(_tutorial):
		return
	var who := player_name if player_name != "" else "Aprendiz"
	NetworkManager.start_tutorial_game(who, TutorialOverlay.HANDS, TutorialOverlay.DECK, TutorialOverlay.RIVAL_NAME)
	var guide := TutorialOverlay.new()
	_tutorial = guide
	add_child(guide)
	guide.finished.connect(_end_tutorial)
	# El guía no conoce la interfaz: le basta con poder preguntar dónde está un
	# control y decir cuáles se pueden tocar. Dos Callables y nada más.
	guide.setup(
		func(key: String) -> Rect2: return _rect_of(key),
		func(keys: Array) -> void: set_input_gate(keys))

## Se llama tanto al terminar el guion como al saltárselo. Devuelve el control
## al jugador y descongela al rival, así que quien se lo salte se queda en una
## partida normal en vez de en una mesa muerta.
func _end_tutorial() -> void:
	_tutorial = null
	NetworkManager.tutorial_mode = false
	NetworkManager.tutorial_bots_paused = false
	GameLogic.burn_window_ms = GameLogic.BURN_WINDOW_MS
	clear_input_gate()

## ---------- DESPACHO DE RENDER ----------

func _render() -> void:
	var st: Dictionary = GameLogic.state
	if st.is_empty():
		return
	# El evento se anota ANTES de reconstruir: la pantalla nueva ya sabe qué
	# nodo esconder hasta que aterrice la carta que vuela.
	var fx: Dictionary = st.get("fx", {})
	if not fx.is_empty() and int(fx.get("seq", 0)) != _last_fx_seq:
		_last_fx_seq = int(fx.get("seq", 0))
		_pending_fx = fx

	# Sonidos de cambio de fase. Van aquí y no en cada pantalla porque esas se
	# redibujan muchas veces seguidas y el sonido se repetiría sin parar.
	var status: String = str(st.get("status", ""))
	if status != _last_status:
		_last_status = status
		if status == "peek":
			Sfx.play("shuffle", 0.0)
		if status != "ended":
			_end_sound_played = false

	match status:
		"lobby": _show_lobby()
		"peek": _show_peek()
		"playing": _show_game()
		"ended": _show_end()

## ---------- SALA DE ESPERA ----------

func _show_lobby() -> void:
	_clear(content)
	_close_modal()
	_pending_fx = {}
	_set_bg(true)

	var center := CenterContainer.new()
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(center)
	var box := _col(10)
	box.custom_minimum_size = Vector2(460, 0)
	center.add_child(box)

	var publica: bool = NetworkManager.room_is_public
	box.add_child(_title("Mesa abierta" if publica else "Sala de espera", 26))

	# En una mesa pública el código no sirve de nada: nadie va a escribirlo, la
	# gente llega buscando. Enseñarlo sólo añadiría ruido.
	if not publica:
		var code_panel := _panel(true)
		box.add_child(code_panel)
		var code_box := _col(2)
		code_panel.add_child(code_box)
		code_box.add_child(DutchUI.title(NetworkManager.room_code, 40))
		code_box.add_child(_label("Comparte este código con tus amigos", 12, DutchUI.TEXT_MUTED, true))

	# Mientras el relé no conteste no hay estado que enseñar, y sin este aviso
	# la pantalla se quedaba en blanco sin explicar que está conectando.
	if NetworkManager.link == NetworkManager.Link.CONNECTING:
		box.add_child(_label(
			"Buscando partida..." if NetworkManager.searching else "Conectando con el servidor...",
			13, DutchUI.TEXT_MUTED, true))

	var st: Dictionary = GameLogic.state
	if not st.is_empty():
		var players: Array = st.get("players", [])
		var players_panel := _panel()
		box.add_child(players_panel)
		var players_box := _col(6)
		players_panel.add_child(players_box)
		var pending: Array = GameLogic.lobby_pending_names()
		for p in players:
			var row := _row(8)
			row.alignment = BoxContainer.ALIGNMENT_BEGIN
			players_box.add_child(row)
			var is_bot: bool = bool(p.get("bot", false))
			var is_host_row: bool = p.id == st.host_id
			row.add_child(_avatar(p.name, false, 26))
			var tag := ""
			if is_host_row:
				tag = " · anfitrión"
			elif is_bot:
				tag = " · bot"
			row.add_child(_label("%s%s" % [p.name, tag], 14,
				DutchUI.TEXT_MUTED if is_bot else DutchUI.TEXT))
			row.add_child(_spacer())
			# El anfitrión no se declara listo: su "estoy listo" es pulsar
			# "Iniciar partida", así que marcarlo dos veces sobraría.
			if not is_host_row:
				var ready: bool = bool(p.get("ready_lobby", false))
				row.add_child(_label("LISTO" if ready else "esperando", 12,
					DutchUI.GOLD if ready else DutchUI.TEXT_MUTED))
		for i in range(NetworkManager.MAX_PLAYERS - players.size()):
			players_box.add_child(_label("· hueco libre", 13, Color(DutchUI.TEXT_MUTED, 0.5)))

		# En una mesa pública el anfitrión no sabe si va a aparecer alguien, así
		# que conviene decirle que no tiene por qué esperar de brazos cruzados.
		if publica and NetworkManager.is_host and players.size() < NetworkManager.MAX_PLAYERS:
			box.add_child(_label("Cualquiera que busque partida puede sentarse aquí.", 12, DutchUI.TEXT_MUTED, true))
			box.add_child(_label("Si te cansas de esperar, rellena con bots y empieza.", 12, DutchUI.TEXT_MUTED, true))

		# Rellenar la mesa con bots: para jugar online no hace falta ser cuatro.
		if NetworkManager.is_host:
			var bots: int = 0
			for p in players:
				if bool(p.get("bot", false)):
					bots += 1
			var bot_row := _row(8)
			box.add_child(bot_row)
			var add_bot := _btn("Añadir bot", func(): NetworkManager.request_add_bot())
			add_bot.disabled = players.size() >= NetworkManager.MAX_PLAYERS
			add_bot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bot_row.add_child(add_bot)
			var del_bot := _btn("Quitar bot", func(): NetworkManager.request_remove_bot())
			del_bot.disabled = bots == 0
			del_bot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bot_row.add_child(del_bot)

		var actions := _row(8)
		box.add_child(actions)
		if NetworkManager.is_host:
			var enough: bool = players.size() >= 2
			var everyone: bool = pending.is_empty()
			var texto := "Iniciar partida"
			if not enough:
				texto = "Faltan jugadores o bots"
			elif not everyone:
				texto = "Esperando a %s" % ", ".join(pending)
			var start_btn := _btn(texto, func():
				NetworkManager.request_start_game()
			, true)
			start_btn.disabled = not (enough and everyone)
			start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			actions.add_child(start_btn)
		else:
			# El invitado marca que está: hasta que lo hagan todos, el anfitrión
			# no puede repartir. Es un interruptor, no un botón de un solo uso:
			# si te has precipitado, puedes echarte atrás.
			var me_lobby := _find_me()
			var i_am_ready: bool = bool(me_lobby.get("ready_lobby", false))
			var ready_btn := _btn("Ya no estoy listo" if i_am_ready else "Estoy listo", func():
				NetworkManager.request_lobby_ready(not i_am_ready)
			, not i_am_ready)
			ready_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			actions.add_child(ready_btn)
			box.add_child(_label(
				"Esperando a que el anfitrión reparta..." if i_am_ready
				else "Avisa cuando estés preparado para empezar",
				13, DutchUI.TEXT_MUTED, true))
		var leave := _btn("Salir", func(): _back_to_menu())
		leave.custom_minimum_size = Vector2(120, 44)
		actions.add_child(leave)
	else:
		var leave2 := _btn("Salir", func(): _back_to_menu())
		leave2.custom_minimum_size = Vector2(120, 44)
		var leave_row := _row()
		leave_row.add_child(leave2)
		box.add_child(leave_row)

## ---------- MIRAR CARTAS ----------

func _show_peek() -> void:
	_clear(content)
	_close_modal()
	_pending_fx = {}
	_set_bg(false)
	_peek_busy = false

	var me := _find_me()
	if me.is_empty():
		return

	content.add_child(_spacer(4))
	content.add_child(_title("Mira 2 de tus cartas", 26))
	content.add_child(_label("No podrás volver a mirarlas: memorízalas bien", 13, DutchUI.TEXT_MUTED, true))

	var fan := CardFan.new()
	fan.card_size = HAND_CARD
	fan.gap = 16.0
	fan.max_angle_deg = 8.0
	fan.arc_lift = 8.0
	fan.custom_minimum_size = Vector2(0, HAND_CARD.y + 20)
	content.add_child(fan)
	# Se registran los controles de esta pantalla para que el tutorial guiado
	# pueda señalarlos y limitar lo que se puede tocar. Comparte el mismo
	# registro que las animaciones de cartas, que se rehace en cada render.
	_clear_anchors()
	_register("hand_row", fan)

	for i in range(me.hand.size()):
		var already: bool = me.peeked_idx.has(i)
		var cv := _card(HAND_CARD)
		cv.set_back()
		cv.dim = already
		fan.add_child(cv)
		var can_tap: bool = (not me.ready_peek) and me.peeked_idx.size() < 2 and not already
		if can_tap:
			var idx := i
			var card_value: String = me.hand[i]
			cv.pressed.connect(func(): _do_peek(cv, idx, card_value))
		else:
			cv.set_interactive(false)
		_register("hand_%d" % i, cv)

	var actions := _row(10)
	content.add_child(actions)
	if me.ready_peek:
		var names: Array = []
		for p in GameLogic.state.players:
			if not p.ready_peek:
				names.append(p.name)
		var waiting_text := "Esperando a: %s" % ", ".join(names) if names.size() > 0 else "Todos listos..."
		actions.add_child(_label(waiting_text, 14, DutchUI.TEXT_MUTED, true))
	else:
		var ready_btn := _btn("Estoy listo" if me.peeked_idx.size() >= 2 else "Elige 2 cartas (%d/2)" % me.peeked_idx.size(), func():
			if NetworkManager.local_mode:
				NetworkManager.request_player_ready()
			else:
				NetworkManager.request_player_ready()
		, true)
		ready_btn.disabled = me.peeked_idx.size() < 2
		ready_btn.custom_minimum_size = Vector2(220, 44)
		actions.add_child(ready_btn)
		_register("ready_btn", ready_btn)
	content.add_child(_spacer())
	_apply_gate()

## Voltea la carta en su sitio, deja unos segundos para memorizarla con la
## cuenta atrás debajo y la vuelve a poner boca abajo. Sólo entonces se avisa
## al servidor, para que la reconstrucción de pantalla no corte el volteo.
func _do_peek(cv: CardView, idx: int, card_value: String) -> void:
	if _peek_busy:
		return
	_peek_busy = true
	cv.set_interactive(false)
	cv.flip_to(card_value, true)

	var tw := create_tween()
	tw.tween_method(func(t: float):
		if is_instance_valid(cv):
			cv.set_progress(t)
	, 1.0, 0.0, 2.6)
	await tw.finished

	if is_instance_valid(cv):
		cv.set_progress(-1.0)
		cv.flip_to("", false)
		cv.dim = true
		cv.queue_redraw()
		await get_tree().create_timer(0.34).timeout

	_peek_busy = false
	if NetworkManager.local_mode:
		NetworkManager.request_peek(idx)
	else:
		NetworkManager.request_peek(idx)

func _find_me() -> Dictionary:
	for p in GameLogic.state.get("players", []):
		if p.id == NetworkManager.my_id:
			return p
	return {}

## ---------- PARTIDA ----------
##
## Reparto horizontal: rivales arriba, montones en medio, tu mano abajo y la
## columna de acciones a la derecha, que es donde llega el pulgar cuando
## sujetas el móvil apaisado.

func _show_game() -> void:
	_clear(content)
	_set_bg(false)
	_clear_anchors()
	_hidden_by_fx.clear()
	# Los nodos recién liberados siguen siendo "válidos" hasta el final del
	# frame, así que sin esto el tick escribiría sobre botones que ya mueren.
	_discard_card = null
	_draw_deck_btn = null
	_draw_discard_btn = null
	_dutch_btn = null
	_burn_btn = null
	_burn_label = null

	var st: Dictionary = GameLogic.state
	var me := _find_me()
	if me.is_empty():
		return
	var turn_player: Dictionary = st.players[st.turn_index]
	var my_turn: bool = turn_player.id == NetworkManager.my_id
	var burn_active: bool = GameLogic.burn_window_active() and st.pending_special.is_empty()
	var turn_changed: bool = turn_player.id != _last_turn_id
	_last_turn_id = turn_player.id

	var fx_kind: String = _pending_fx.get("kind", "")
	var fx_moves_discard: bool = fx_kind in ["discard", "burn_ok", "swap"]
	var fx_moves_drawn: bool = fx_kind == "draw"

	# --- barra superior ---
	var top := _row(8)
	# Altura mínima igual a la del mando de volumen: éste flota anclado a la
	# esquina y no participa del reparto, así que si la fila fuera más baja se
	# le echaría encima al primer botón de la columna de acciones.
	top.custom_minimum_size = Vector2(0, VolumeWidget.SIZE.y + 8.0)
	content.add_child(top)
	var banner := PanelContainer.new()
	var banner_sb := DutchUI.box(DutchUI.GOLD if my_turn else DutchUI.PANEL, DutchUI.GOLD_DARK if my_turn else DutchUI.PANEL_BORDER, 2)
	DutchUI.shadowed(banner_sb, 2, 0.5, Vector2(3, 3))
	banner.add_theme_stylebox_override("panel", banner_sb)
	banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(banner)
	var banner_text := ("¡ES TU TURNO!" if my_turn else "Turno de %s" % turn_player.name.to_upper())
	banner.add_child(DutchUI.title(banner_text, 20, DutchUI.TEXT_DARK if my_turn else DutchUI.GOLD))
	if turn_changed:
		_animate_pop(banner)
		if my_turn:
			Sfx.play("turn", 0.0)

	var round_panel := _panel()
	top.add_child(round_panel)
	if st.dutch_caller_id != -1:
		var caller_name := "?"
		for p in st.players:
			if p.id == st.dutch_caller_id:
				caller_name = p.name
		round_panel.add_child(_label("DUTCH de %s · última vuelta" % caller_name, 13, DutchUI.EMBER))
	else:
		round_panel.add_child(_label("Ronda %d" % st.get("round_number", 1), 13, DutchUI.TEXT_MUTED))
	# Sitio para el mando de música, que va flotando sobre esta misma esquina.
	top.add_child(_gap(VolumeWidget.SIZE.x + 6.0))

	# --- cuerpo ---
	var body := _row(10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.alignment = BoxContainer.ALIGNMENT_BEGIN
	content.add_child(body)

	var left := _col(6)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(left)

	# rivales
	var opp_row := _row(8)
	left.add_child(opp_row)
	for p in st.players:
		if p.id == NetworkManager.my_id:
			continue
		var is_turn: bool = p.id == turn_player.id
		var seat := _panel(is_turn)
		opp_row.add_child(seat)
		_register("seat_%d" % p.id, seat)

		var seat_box := _col(3)
		seat.add_child(seat_box)
		var head := _row(6)
		seat_box.add_child(head)
		head.add_child(_avatar(p.name, is_turn, 24))
		head.add_child(_label(p.name, 14, DutchUI.TEXT if is_turn else DutchUI.TEXT_MUTED))
		head.add_child(_label("(%d)" % p.hand.size(), 12, DutchUI.TEXT_MUTED))

		# En abanico y no en fila: una quemada fallida da carta extra, y con 7
		# cartas una fila de tamaño fijo se saldría del asiento.
		var mini_row := CardFan.new()
		mini_row.card_size = MINI_CARD
		mini_row.gap = 4.0
		mini_row.max_angle_deg = 6.0
		mini_row.arc_lift = 3.0
		mini_row.custom_minimum_size = Vector2(MINI_CARD.x * 4 + 12, MINI_CARD.y + 6)
		seat_box.add_child(mini_row)
		for i in range(p.hand.size()):
			var mc := _mini_card()
			mini_row.add_child(mc)
			_register("mini_%d_%d" % [p.id, i], mc)

	left.add_child(_spacer())

	# montones
	var piles := _row(26)
	left.add_child(piles)

	var deck_box := _col(2)
	piles.add_child(deck_box)
	var deck_card := _card(PILE_CARD)
	deck_card.set_back()
	deck_card.stack_depth = clampi(int(st.deck.size() / 8.0), 0, 3)
	deck_card.set_interactive(false)
	deck_box.add_child(deck_card)
	deck_box.add_child(_label("Mazo · %d" % st.deck.size(), 12, DutchUI.TEXT_MUTED, true))
	_register("deck", deck_card)

	var discard_box := _col(2)
	piles.add_child(discard_box)
	var discard_card := _card(PILE_CARD)
	var new_discard_top: String = (st.discard[-1] if st.discard.size() > 0 else "")
	var discard_changed: bool = new_discard_top != _last_discard_top
	_last_discard_top = new_discard_top
	if new_discard_top != "":
		discard_card.set_card(new_discard_top, true)
		discard_card.stack_depth = clampi(st.discard.size() - 1, 0, 2)
	else:
		discard_card.set_empty()
	# Una carta quemada sigue admitiendo quemadas encima, así que el montón
	# se puede seguir tocando aunque ya no se pueda robar.
	_discard_burned = GameLogic.discard_is_burned() and new_discard_top != ""
	discard_card.burned = _discard_burned
	if not st.discard.is_empty() and st.active_draw.is_empty() and st.pending_special.is_empty():
		discard_card.pressed.connect(func(): _open_burn_modal())
	else:
		discard_card.set_interactive(false)
	discard_box.add_child(discard_card)
	discard_box.add_child(_label(
		"QUEMADA" if _discard_burned else "Descarte",
		12, DutchUI.EMBER if _discard_burned else DutchUI.TEXT_MUTED, true))
	_register("discard", discard_card)
	_discard_card = discard_card
	if fx_moves_discard and new_discard_top != "":
		_hide_until_landing(discard_card)
	elif discard_changed and new_discard_top != "":
		_animate_card_in(discard_card)
	if burn_active and new_discard_top != "":
		discard_card.pulse(true)

	# carta robada (sólo la mía), justo al lado de los montones para que el
	# vuelo mazo -> mano se lea de un vistazo
	var has_active_draw_mine: bool = not st.active_draw.is_empty() and st.active_draw.player_id == NetworkManager.my_id
	if has_active_draw_mine:
		var drawn_box := _col(2)
		piles.add_child(drawn_box)
		var drawn_card := _card(PILE_CARD)
		drawn_card.set_card(st.active_draw.card, true)
		drawn_card.selected = true
		drawn_card.set_interactive(false)
		drawn_box.add_child(drawn_card)
		drawn_box.add_child(_label("Robada", 12, DutchUI.GOLD, true))
		_register("drawn", drawn_card)
		var drawn_changed: bool = st.active_draw.card != _last_drawn_card
		_last_drawn_card = st.active_draw.card
		if fx_moves_drawn:
			_hide_until_landing(drawn_card)
		elif drawn_changed:
			_animate_card_in(drawn_card)
	else:
		_last_drawn_card = ""

	_burn_label = _label("", 14, DutchUI.EMBER, true)
	_burn_label.visible = false
	left.add_child(_burn_label)
	left.add_child(_spacer())

	# mi mano
	if has_active_draw_mine:
		left.add_child(_label("Toca una carta de tu mano para cambiarla", 13, DutchUI.GOLD, true))
	else:
		left.add_child(_label("Tu mano", 12, DutchUI.TEXT_MUTED, true))
	var hand_fan := CardFan.new()
	hand_fan.card_size = HAND_CARD
	hand_fan.gap = 10.0
	hand_fan.max_angle_deg = 8.0
	hand_fan.arc_lift = 6.0
	hand_fan.custom_minimum_size = Vector2(0, HAND_CARD.y + 12)
	left.add_child(hand_fan)
	_register("hand_row", hand_fan)
	for i in range(me.hand.size()):
		var idx := i
		var cv := _card(HAND_CARD)
		cv.set_back()
		hand_fan.add_child(cv)
		_register("hand_%d" % i, cv)
		# pulse() necesita que la carta ya esté en el árbol para crear su
		# tween, así que se llama después de add_child, no antes.
		if has_active_draw_mine:
			cv.pressed.connect(func(): NetworkManager.request_swap(idx))
			cv.pulse(true)
		else:
			cv.set_interactive(false)

	# --- columna de acciones ---
	_pending_special_empty = st.pending_special.is_empty()
	_can_act_base = my_turn and st.active_draw.is_empty() and _pending_special_empty
	_discard_is_empty = st.discard.is_empty()
	_deck_can_serve = GameLogic.deck_can_serve()
	_dutch_already_called = st.dutch_caller_id != -1
	_dutch_round_locked = st.get("round_number", 1) < GameLogic.MIN_DUTCH_ROUND
	var can_act: bool = _can_act_base and not burn_active

	var side := _col(6)
	side.custom_minimum_size = Vector2(SIDEBAR_W, 0)
	side.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(side)

	if has_active_draw_mine:
		var drop_btn := _btn("Descartar robada", func():
			NetworkManager.request_discard_drawn()
		, true)
		side.add_child(drop_btn)
		_register("drop_btn", drop_btn)
	else:
		_draw_deck_btn = _btn("Robar del mazo", func(): NetworkManager.request_draw_deck(), true)
		_draw_deck_btn.disabled = not can_act or not _deck_can_serve
		side.add_child(_draw_deck_btn)
		_register("deck_btn", _draw_deck_btn)
		_draw_discard_btn = _btn("Robar del descarte", func(): NetworkManager.request_draw_discard())
		_draw_discard_btn.disabled = not can_act or _discard_is_empty or _discard_burned
		side.add_child(_draw_discard_btn)
		_register("discard_btn", _draw_discard_btn)
		if _discard_burned:
			var warn := _para("Descarte quemado: no se puede robar, sólo quemar encima.", 11, DutchUI.EMBER)
			warn.custom_minimum_size = Vector2(SIDEBAR_W - 8, 0)
			side.add_child(warn)

	_burn_btn = _btn("Quemar carta", func(): _open_burn_modal(), false)
	_burn_btn.disabled = st.discard.is_empty() or not st.pending_special.is_empty() or not st.active_draw.is_empty()
	side.add_child(_burn_btn)
	_register("burn_btn", _burn_btn)

	var dutch_text := "Decir DUTCH"
	if _dutch_round_locked and not _dutch_already_called:
		dutch_text = "DUTCH (ronda %d+)" % GameLogic.MIN_DUTCH_ROUND
	_dutch_btn = _btn(dutch_text, func(): NetworkManager.request_dutch())
	_dutch_btn.disabled = not can_act or _dutch_already_called or _dutch_round_locked
	side.add_child(_dutch_btn)
	_register("dutch_btn", _dutch_btn)

	# registro
	var log_panel := _panel()
	log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(log_panel)
	var log_box := _col(1)
	log_box.alignment = BoxContainer.ALIGNMENT_END
	log_panel.add_child(log_box)
	var recent: Array = st.log.slice(max(0, st.log.size() - 5))
	for i in range(recent.size()):
		# Las líneas viejas se apagan, pero sin bajar de 0.7: por debajo de eso
		# el texto se pierde contra la madera del panel.
		var fade: float = 0.7 + 0.3 * (float(i + 1) / float(recent.size()))
		var line := DutchUI.paragraph(recent[i], 12, Color(DutchUI.TEXT_MUTED, fade), false)
		line.custom_minimum_size = Vector2(SIDEBAR_W - 24, 0)
		log_box.add_child(line)

	_tick_burn_countdown()
	# El modal del 10/11 se abre AQUÍ, así que la restricción del tutorial se
	# aplica después: si no, los controles del modal nacerían sin filtrar.
	_handle_pending_special()
	_apply_gate()
	call_deferred("_flush_fx")

## ---------- MODALES ----------

## Mano en abanico para los modales. Con una fila normal, un jugador que ha
## fallado muchas quemadas acaba con 14 cartas y el panel se sale de la
## pantalla por los dos lados; aquí el ancho está topado y CardFan las solapa
## tanto como haga falta para que quepan siempre.
const MODAL_HAND_MAX_W := 680.0

func _modal_hand(count: int) -> CardFan:
	var fan := CardFan.new()
	fan.card_size = MODAL_CARD
	fan.gap = 8.0
	fan.max_angle_deg = 6.0
	fan.min_visible = 0.28
	var want: float = MODAL_CARD.x * count + 8.0 * max(0, count - 1)
	fan.custom_minimum_size = Vector2(min(MODAL_HAND_MAX_W, want), MODAL_CARD.y + 10.0)
	return fan

func _open_burn_modal() -> void:
	var inner := _modal_box()
	inner.add_child(DutchUI.title("Quemar carta", 24))
	inner.add_child(_label("¿Cuál de tus cartas coincide con la del descarte?", 14, DutchUI.TEXT, true))

	var st: Dictionary = GameLogic.state
	var row := _row(20)
	inner.add_child(row)
	if not st.discard.is_empty():
		var top_box := _col(2)
		row.add_child(top_box)
		var top_card := _card(MODAL_CARD)
		top_card.set_card(st.discard[-1], true)
		top_card.set_interactive(false)
		top_box.add_child(top_card)
		top_box.add_child(_label("Descarte", 12, DutchUI.TEXT_MUTED, true))

	var me := _find_me()
	var hand_box := _col(2)
	row.add_child(hand_box)
	var hand_row := _modal_hand(me.hand.size())
	hand_box.add_child(hand_row)
	_register("modal_burn_row", hand_row)
	for i in range(me.hand.size()):
		var idx := i
		var cv := _card(MODAL_CARD)
		cv.set_back()
		_register("modal_burn_%d" % i, cv)
		cv.pressed.connect(func():
			# Sin _close_modal() aquí: attempt_burn() vuelve a renderizar de
			# forma síncrona antes de que esta línea termine, y si la carta
			# quemada era un 10 u 11 ese render ya ha abierto el modal del
			# efecto. Cerrar sin mirar arrancaba ese modal y dejaba la capa sin
			# recibir toques, bloqueando la partida. Que decida
			# _handle_pending_special().
			NetworkManager.request_burn(idx)
		)
		hand_row.add_child(cv)
	hand_box.add_child(_label("Tu mano", 12, DutchUI.TEXT_MUTED, true))

	inner.add_child(_label("Si fallas te llevas una carta de penalización", 12, DutchUI.EMBER, true))
	var cancel := _btn("Cancelar", func(): _close_modal())
	cancel.custom_minimum_size = Vector2(160, 44)
	var cancel_row := _row()
	cancel_row.add_child(cancel)
	inner.add_child(cancel_row)
	_register("modal_burn_cancel", cancel)
	_apply_gate()

func _close_modal() -> void:
	_clear(modal_layer)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _handle_pending_special() -> void:
	var ps: Dictionary = GameLogic.state.get("pending_special", {})
	if ps.is_empty():
		_close_modal()
		return
	if ps.type == "10":
		if ps.by != NetworkManager.my_id:
			_close_modal()
			return
		if ps.has("peeked_value"):
			_open_ten_result_modal(ps)
		else:
			_open_ten_choose_modal()
	elif ps.type == "11":
		# En el 11 no siempre decide quien lo jugó: el último paso lo resuelve
		# el RIVAL, que elige a ciegas una carta del que lo jugó.
		if GameLogic.eleven_actor(ps) != NetworkManager.my_id:
			_close_modal()
			return
		_open_eleven_modal(ps)

func _modal_box() -> VBoxContainer:
	_clear(modal_layer)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.8)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_layer.add_child(bg)
	_animate_fade_in(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Con el tutorial en marcha el modal se centra más abajo: el globo de texto
	# del guion vive arriba mientras hay un modal abierto (si se quedara abajo
	# taparía justo las cartas que hay que tocar) y así no se solapan.
	if _gate_active:
		center.offset_top = 150
	bg.add_child(center)
	var box := _panel(true)
	center.add_child(box)
	var inner := _col(10)
	box.add_child(inner)
	_animate_pop(box)
	return inner

func _open_ten_choose_modal() -> void:
	var inner := _modal_box()
	inner.add_child(DutchUI.title("Efecto del 10", 24))
	inner.add_child(_label("Elige una de TUS cartas para recordarla", 14, DutchUI.TEXT, true))
	var me := _find_me()
	var row := _modal_hand(me.hand.size())
	inner.add_child(row)
	_register("modal_ten_row", row)
	for i in range(me.hand.size()):
		var idx := i
		var my_id: int = NetworkManager.my_id
		var cv := _card(MODAL_CARD)
		cv.set_back()
		cv.pressed.connect(func(): NetworkManager.request_ten_pick(my_id, idx))
		row.add_child(cv)
		_register("modal_ten_%d" % i, cv)

func _open_ten_result_modal(ps: Dictionary) -> void:
	var inner := _modal_box()
	inner.add_child(DutchUI.title("Efecto del 10", 24))
	inner.add_child(_label(ps.peeked_label, 14, DutchUI.TEXT, true))
	var row := _row()
	inner.add_child(row)
	var cv := _card(Vector2(120, 168))
	cv.set_back()
	cv.set_interactive(false)
	row.add_child(cv)
	# Se revela volteándola, no apareciendo ya girada: el gesto es el mismo que
	# cuando miras tus cartas al principio.
	cv.flip_to(ps.peeked_value, true)
	Sfx.play("chime", 0.0)
	var ok := _btn("Vale, ya me acuerdo", func(): NetworkManager.request_ten_ack(), true)
	ok.custom_minimum_size = Vector2(240, 44)
	var ok_row := _row()
	ok_row.add_child(ok)
	inner.add_child(ok_row)
	_register("modal_ten_ok", ok)

func _open_eleven_modal(ps: Dictionary) -> void:
	var inner := _modal_box()
	inner.add_child(DutchUI.title("Efecto del 11", 24))

	if ps.target_id == -1:
		# Paso 1 — lo elige quien jugó el 11.
		inner.add_child(_label("Intercambio a ciegas: elige un rival", 14, DutchUI.TEXT, true))
		var row := _row(8)
		inner.add_child(row)
		for p in GameLogic.state.players:
			if p.id == NetworkManager.my_id:
				continue
			var pid: int = p.id
			var b := _btn(p.name, func(): NetworkManager.request_eleven_target(pid))
			b.custom_minimum_size = Vector2(150, 44)
			row.add_child(b)
			_register("modal_11_target_%d" % pid, b)
	elif ps.target_slot == -1:
		# Paso 2 — quien jugó el 11 se lleva una carta del rival, a ciegas.
		var target := _player_by_id(ps.target_id)
		inner.add_child(_label("Quédate con una carta de %s (a ciegas)" % target.get("name", "?"), 14, DutchUI.TEXT, true))
		var row3 := _modal_hand(target.hand.size())
		inner.add_child(row3)
		_register("modal_11_take_row", row3)
		for i in range(target.hand.size()):
			var idx := i
			var cv := _card(MODAL_CARD)
			cv.set_back()
			cv.pressed.connect(func(): NetworkManager.request_eleven_target_slot(idx))
			row3.add_child(cv)
			_register("modal_11_take_%d" % i, cv)
	elif ps.my_slot == -1:
		# Paso 3 — y este lo resuelve el RIVAL, no quien jugó el 11: se lleva a
		# ciegas una carta suya. Nadie elige qué carta propia entrega.
		var caller := _player_by_id(ps.by)
		inner.add_child(_label("%s te ha robado una carta. Quédate tú una suya (a ciegas)" % caller.get("name", "?"), 14, DutchUI.TEXT, true))
		var row2 := _modal_hand(caller.hand.size())
		inner.add_child(row2)
		_register("modal_11_give_row", row2)
		for i in range(caller.hand.size()):
			var idx := i
			var cv := _card(MODAL_CARD)
			cv.set_back()
			cv.pressed.connect(func(): NetworkManager.request_eleven_my_slot(idx))
			row2.add_child(cv)
			_register("modal_11_give_%d" % i, cv)

func _player_by_id(pid) -> Dictionary:
	for p in GameLogic.state.get("players", []):
		if p.id == pid:
			return p
	return {}

## ---------- FINAL ----------
##
## La lista de resultados va dentro de un ScrollContainer y los botones fuera,
## anclados abajo: con cuatro o cinco jugadores la tabla no cabe en 540 px de
## alto y antes se comía el botón de volver a jugar.

func _show_end() -> void:
	_clear(content)
	_close_modal()
	_pending_fx = {}
	_set_bg(true)

	var results: Dictionary = GameLogic.state.get("results", {})
	if results.is_empty():
		return

	var winner_ids: Array = results.winner_ids
	var i_won: bool = winner_ids.has(NetworkManager.my_id)

	var head := _col(2)
	content.add_child(head)
	head.add_child(_title("¡Has ganado!" if i_won else "Gana %s" % ", ".join(_winner_names(results)), 30))
	# Deja claro POR QUÉ ha terminado: sin esto la pantalla parece salir de la
	# nada, sobre todo si estabas en mitad del efecto de un 10 o un 11.
	var log: Array = GameLogic.state.get("log", [])
	if log.size() > 0:
		head.add_child(_label(log[-1], 12, DutchUI.TEXT_MUTED, true))
	# Una sola vez por partida: esta pantalla se reconstruye con cada cambio de
	# estado y la fanfarria no puede sonar en bucle.
	if not _end_sound_played:
		_end_sound_played = true
		Sfx.play("win" if i_won else "lose", 0.0)
	if i_won:
		_flourish("¡GANASTE!")

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	var rows_box := _col(6)
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows_box)

	var rows: Array = results.rows.duplicate()
	rows.sort_custom(func(a, b): return a.total < b.total)
	for i in range(rows.size()):
		var r: Dictionary = rows[i]
		var won: bool = winner_ids.has(r.id)
		var row_panel := _panel(won)
		rows_box.add_child(row_panel)

		var line := _row(10)
		line.alignment = BoxContainer.ALIGNMENT_BEGIN
		row_panel.add_child(line)
		line.add_child(_avatar(r.name, won, 26))
		var name_label := _label(r.name, 15, DutchUI.GOLD if won else DutchUI.TEXT)
		name_label.custom_minimum_size = Vector2(120, 0)
		line.add_child(name_label)

		# En abanico y con tope de ancho: quien acumula muchas cartas por fallar
		# quemadas se salía de la fila del marcador.
		var hand_row := CardFan.new()
		hand_row.card_size = MINI_CARD
		hand_row.gap = 4.0
		hand_row.min_visible = 0.30
		var want: float = MINI_CARD.x * r.hand.size() + 4.0 * max(0, r.hand.size() - 1)
		hand_row.custom_minimum_size = Vector2(min(520.0, want), MINI_CARD.y)
		line.add_child(hand_row)
		for j in range(r.hand.size()):
			var cv := _card(MINI_CARD)
			cv.set_back()
			cv.set_interactive(false)
			hand_row.add_child(cv)
			# Revelado escalonado: las manos se destapan una carta detrás de
			# otra, como cuando se enseñan de verdad al final de una mano.
			var card_id: String = r.hand[j]
			var delay: float = 0.2 + i * 0.2 + j * 0.08
			get_tree().create_timer(delay).timeout.connect(func():
				if is_instance_valid(cv):
					cv.flip_to(card_id, true)
			)

		line.add_child(_spacer())
		line.add_child(DutchUI.title("%d" % r.total, 24, DutchUI.GOLD if won else DutchUI.TEXT))

	var actions := _row(10)
	content.add_child(actions)
	if NetworkManager.is_host:
		var again := _btn("Jugar otra vez", func(): NetworkManager.request_play_again(), true)
		again.custom_minimum_size = Vector2(240, 46)
		actions.add_child(again)
	else:
		actions.add_child(_label("Esperando a que el anfitrión reparta otra...", 13, DutchUI.TEXT_MUTED, true))
	var menu := _btn("Menú principal", func(): _back_to_menu())
	menu.custom_minimum_size = Vector2(200, 46)
	actions.add_child(menu)

func _back_to_menu() -> void:
	# El guion se cierra ANTES de vaciar el estado: si sobreviviera al volver al
	# menú se quedaría esperando eternamente una jugada de una partida que ya no
	# existe, con el globo de texto colgado en pantalla.
	if is_instance_valid(_tutorial):
		_tutorial.abort()
	_end_tutorial()
	NetworkManager.leave_game()
	_last_status = ""
	_end_sound_played = false
	_last_turn_id = -999
	_last_discard_top = ""
	_last_drawn_card = ""
	_last_fx_seq = 0
	_anchors.clear()
	_prev_rects.clear()
	_hidden_by_fx.clear()
	_show_home()

func _winner_names(results: Dictionary) -> Array:
	var names: Array = []
	for r in results.rows:
		if results.winner_ids.has(r.id):
			names.append(r.name)
	return names
