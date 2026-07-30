class_name VolumeWidget
extends Control
## VolumeWidget.gd
## Control de música de la esquina: altavoz (toca para silenciar) + barra
## deslizante (arrastra para ajustar el volumen). Siempre visible, en el menú
## y en plena partida.
##
## Antes eran cinco barritas independientes de 4 píxeles de ancho cada una:
## acertar la que querías con el dedo era impreciso. Una barra deslizante es
## mucho más tolerante — arrastras hacia donde quieras sin tener que acertar
## un punto exacto — y es el gesto que cualquiera reconoce de un mando de
## volumen real.

## Lado del píxel del mando. Todo se mide en múltiplos de esto.
const U := 3.0
const BARS := 5  # niveles además del 0 (silencio); igual que Music.MAX_LEVEL
## Más ancha que la versión de barritas: da sitio de sobra al recorrido del
## dedo. Más alta: así el propio dedo no tapa el resto de la interfaz al usar
## el mando.
const SIZE := Vector2(52.0 * U, 18.0 * U)

const SPEAKER_W := 13.0 * U
const TRACK_X0 := 17.0 * U
const TRACK_X1 := 48.0 * U

## Volumen al que se vuelve al desmutear.
var _last_level: int = 4
## Mientras se arrastra, se sigue recibiendo el movimiento aunque el dedo se
## desvíe un poco de la franja de la barra: es lo que hace que arrastrar sea
## tolerante en vez de exigir precisión de aguja.
var _dragging: bool = false

func _init() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	size = SIZE
	if Music.volume_level > 0:
		_last_level = Music.volume_level

func _level_at(x: float) -> int:
	var t: float = clamp((x - TRACK_X0) / (TRACK_X1 - TRACK_X0), 0.0, 1.0)
	return clampi(int(round(t * BARS)), 0, BARS)

func _gui_input(event: InputEvent) -> void:
	var pos := Vector2.INF
	var pressed := false
	var released := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		pressed = event.pressed
		released = not event.pressed
	elif event is InputEventScreenTouch:
		pos = event.position
		pressed = event.pressed
		released = not event.pressed
	elif event is InputEventMouseMotion and _dragging:
		pos = event.position
	elif event is InputEventScreenDrag and _dragging:
		pos = event.position
	else:
		return

	if pressed:
		if pos.x < SPEAKER_W:
			# Botón de silencio: acción inmediata, no se arrastra.
			if Music.volume_level > 0:
				_last_level = Music.volume_level
				Music.set_level(0)
			else:
				Music.set_level(max(1, _last_level))
		else:
			# Tocar en cualquier punto de la barra salta directamente a ese
			# volumen, además de empezar a poder arrastrar desde ahí.
			_dragging = true
			Music.set_level(_level_at(pos.x))
	elif released:
		_dragging = false
	elif _dragging:
		Music.set_level(_level_at(pos.x))

	if Music.volume_level > 0:
		_last_level = Music.volume_level
	queue_redraw()
	accept_event()

func _frame(r: Rect2, color: Color, t: float) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - t), Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(r.position, Vector2(t, r.size.y)), color, true)
	draw_rect(Rect2(Vector2(r.end.x - t, r.position.y), Vector2(t, r.size.y)), color, true)

func _draw() -> void:
	var lvl: int = Music.volume_level
	var body := Rect2(0, 0, size.x - U, size.y - U)
	var cy: float = body.size.y * 0.5

	# Sombra dura desplazada y cuerpo de madera, igual que los paneles.
	draw_rect(Rect2(U, U, body.size.x, body.size.y), Color(0, 0, 0, 0.45), true)
	draw_rect(body, DutchUI.PANEL, true)
	_frame(body, DutchUI.PANEL_BORDER, U)

	var on_color := DutchUI.GOLD if lvl > 0 else DutchUI.TEXT_MUTED

	# Altavoz: caja, cono en tres escalones y dos ondas (o el aspa de muteado).
	draw_rect(Rect2(2.0 * U, cy - U, 2.0 * U, 2.0 * U), on_color, true)
	for k in range(3):
		draw_rect(Rect2((4.0 + k) * U, cy - (1.0 + k) * U, U, (2.0 + 2.0 * k) * U), on_color, true)
	if lvl > 0:
		draw_rect(Rect2(8.0 * U, cy - U, U, 2.0 * U), on_color, true)
		draw_rect(Rect2(9.0 * U, cy - 2.0 * U, U, 4.0 * U), on_color, true)
	else:
		for k in range(3):
			draw_rect(Rect2((8.0 + k) * U, cy + (k - 1) * U, U, U), DutchUI.DANGER, true)
			draw_rect(Rect2((8.0 + k) * U, cy + (1 - k) * U, U, U), DutchUI.DANGER, true)

	# Separador entre el altavoz y la barra.
	draw_rect(Rect2(SPEAKER_W - U * 0.5, U * 2.0, U * 0.5, body.size.y - U * 4.0), Color(DutchUI.PANEL_BORDER, 0.8), true)

	# Surco de la barra: hundido, con marcas en cada uno de los 6 niveles.
	var track_h := U * 2.0
	var track_y0 := cy - track_h * 0.5
	var groove := Rect2(TRACK_X0, track_y0, TRACK_X1 - TRACK_X0, track_h)
	draw_rect(groove, DutchUI.PANEL_DEEP, true)
	_frame(groove, Color(0, 0, 0, 0.6), max(1.0, U * 0.4))
	for i in range(BARS + 1):
		var tx: float = TRACK_X0 + (TRACK_X1 - TRACK_X0) * (float(i) / float(BARS))
		draw_rect(Rect2(tx - U * 0.15, track_y0 - U * 0.6, U * 0.3, track_h + U * 1.2), Color(DutchUI.TEXT_MUTED, 0.4), true)

	# Relleno hasta el nivel actual, como una barra de progreso.
	var thumb_x: float = TRACK_X0 + (TRACK_X1 - TRACK_X0) * (float(lvl) / float(BARS))
	if lvl > 0:
		draw_rect(Rect2(TRACK_X0, track_y0, thumb_x - TRACK_X0, track_h), DutchUI.GOLD, true)
		draw_rect(Rect2(TRACK_X0, track_y0, thumb_x - TRACK_X0, U * 0.5), DutchUI.GOLD.lightened(0.3), true)

	# El mango: un bloque más alto que la barra, para que se vea bien dónde
	# agarrar y arrastrar.
	var thumb_w := U * 3.0
	var thumb_h := U * 7.0
	var thumb := Rect2(thumb_x - thumb_w * 0.5, cy - thumb_h * 0.5, thumb_w, thumb_h)
	draw_rect(Rect2(thumb.position + Vector2(U * 0.5, U * 0.5), thumb.size), Color(0, 0, 0, 0.4), true)
	draw_rect(thumb, on_color, true)
	_frame(thumb, DutchUI.PANEL_DEEP, max(1.0, U * 0.5))
	if lvl > 0:
		draw_rect(Rect2(thumb.position, Vector2(thumb.size.x, U * 0.6)), Color(1, 1, 1, 0.35), true)
