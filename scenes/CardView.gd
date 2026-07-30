class_name CardView
extends Control
## CardView.gd
## Muestra una carta de la baraja española como pixel art.
##
## El dibujo real lo hace PixelArt, que genera una imagen de 40x56 píxeles por
## carta. Aquí sólo se pinta esa textura escalada por un múltiplo entero con
## filtro NEAREST, de forma que los píxeles salen cuadrados y del mismo tamaño
## en toda la pantalla. Por eso cualquier tamaño que se le dé a una carta debe
## ser 40x56, 80x112, 120x168...
##
## Encima de la textura se dibujan los estados del juego (seleccionada, halo de
## aviso, cuenta atrás para quemar) y las animaciones: volteo, elevación y
## sacudida de error.

signal pressed

const GOLD := Color("#e8b84b")
const EMBER := Color("#ff8c3a")

@export var card_id: String = ""   # p. ej. "oros-12"; se ignora si no está boca arriba
@export var face_up: bool = false
@export var selected: bool = false
@export var dim: bool = false
@export var empty: bool = false    # sólo el hueco punteado
@export var stack_depth: int = 0   # cartas extra dibujadas debajo (aspecto de montón)
@export var interactive: bool = true
## Carta quemada en el descarte: se sigue viendo (hace falta para saber qué
## número hay que emparejar) pero queda marcada como no robable.
@export var burned: bool = false
## Bloqueo del tutorial: la carta no responde, aunque la partida sí la
## consideraría pulsable. Va aparte de `interactive` a propósito: así el guion
## puede bloquear y desbloquear sin pisar lo que la partida haya decidido.
@export var locked: bool = false

## 0..1 dibuja una barra de cuenta atrás bajo la carta; negativo la apaga.
var timer_progress: float = -1.0

var _lift: float = 0.0     # píxeles que la carta se separa de la mesa
var _flip: float = 1.0     # 1 = de frente, 0 = de canto (mitad del volteo)
var _glow: float = 0.0     # halo de atención (0..1)
var _shake: float = 0.0
var _pulse: Tween = null

func _init() -> void:
	custom_minimum_size = Vector2(PixelArt.W, PixelArt.H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _ready() -> void:
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))

func _on_hover(inside: bool) -> void:
	if not _pressable():
		return
	_tween_lift(_unit() * 2.0 if inside else 0.0)

func set_interactive(v: bool) -> void:
	interactive = v
	mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE

func set_locked(v: bool) -> void:
	if locked == v:
		return
	locked = v
	queue_redraw()

func _pressable() -> bool:
	return interactive and not locked

## Cuántos píxeles de pantalla mide un píxel de la carta. Todas las medidas de
## los adornos se expresan en esta unidad para que nada quede a medio píxel.
func _unit() -> float:
	return max(1.0, floor(size.y / float(PixelArt.H)))

## ---------- API ----------

func set_card(id: String, up: bool) -> void:
	card_id = id
	face_up = up
	empty = false
	queue_redraw()

func set_back() -> void:
	card_id = ""
	face_up = false
	empty = false
	queue_redraw()

func set_empty() -> void:
	empty = true
	queue_redraw()

## Voltea pasando por el canto: el valor cambia justo cuando la carta está de
## perfil, así que nunca se ve antes de tiempo.
func flip_to(id: String, up: bool) -> void:
	if not is_inside_tree():
		set_card(id, up)
		return
	Sfx.play("flip", 0.10)
	var tw := create_tween()
	tw.tween_method(_set_flip, _flip, 0.0, 0.14).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_callback(func():
		card_id = id
		face_up = up
		empty = false
	)
	tw.tween_method(_set_flip, 0.0, 1.0, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func set_flip(v: float) -> void:
	_set_flip(v)

func set_lift(v: float) -> void:
	_lift = v
	queue_redraw()

func set_glow(v: float) -> void:
	_glow = v
	queue_redraw()

func pulse(on: bool) -> void:
	if is_instance_valid(_pulse):
		_pulse.kill()
		_pulse = null
	if not on or not is_inside_tree():
		set_glow(0.0)
		return
	_pulse = create_tween().set_loops()
	_pulse.tween_method(set_glow, 0.0, 1.0, 0.55).set_trans(Tween.TRANS_SINE)
	_pulse.tween_method(set_glow, 1.0, 0.0, 0.55).set_trans(Tween.TRANS_SINE)

func shake() -> void:
	if not is_inside_tree():
		return
	var u := _unit()
	var tw := create_tween()
	for i in range(4):
		var dir := 1.0 if i % 2 == 0 else -1.0
		tw.tween_method(_set_shake, _shake, dir * u * (3.0 - i * 0.6), 0.05)
	tw.tween_method(_set_shake, _shake, 0.0, 0.05)

func set_progress(t: float) -> void:
	if is_equal_approx(timer_progress, t):
		return
	timer_progress = t
	queue_redraw()

## ---------- INTERNO ----------

func _set_flip(v: float) -> void:
	_flip = v
	queue_redraw()

func _set_shake(v: float) -> void:
	_shake = v
	queue_redraw()

func _tween_lift(to: float) -> void:
	if not is_inside_tree():
		set_lift(to)
		return
	create_tween().tween_method(set_lift, _lift, to, 0.10).set_trans(Tween.TRANS_QUAD)

func _gui_input(event: InputEvent) -> void:
	if not _pressable():
		return
	var released := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		released = true
	elif event is InputEventScreenTouch and not event.pressed:
		released = true
	elif event is InputEventScreenTouch and event.pressed:
		_tween_lift(_unit() * 3.0)
	if released:
		_tween_lift(0.0)
		Sfx.play("card")
		pressed.emit()

## ---------- DIBUJO ----------

func _texture() -> Texture2D:
	if empty:
		return PixelArt.empty_texture()
	if face_up and card_id != "":
		return PixelArt.card_texture(card_id)
	return PixelArt.back_texture()

func _draw() -> void:
	var u := _unit()
	var rect := Rect2(Vector2.ZERO, size)
	var cx := size.x * 0.5
	# El volteo escala en horizontal alrededor del eje central; la elevación
	# sube la carta pero no su sombra, que es lo que la despega de la mesa.
	var flat := Transform2D(0.0, Vector2(_flip, 1.0), 0.0, Vector2(cx * (1.0 - _flip) + _shake, 0.0))
	var lifted := Transform2D(0.0, Vector2(_flip, 1.0), 0.0, Vector2(cx * (1.0 - _flip) + _shake, -_lift))

	if empty:
		draw_set_transform_matrix(flat)
		draw_texture_rect(PixelArt.empty_texture(), rect, false)
		return

	# Sombra dura, sin degradado: en pixel art una sombra difuminada canta.
	draw_set_transform_matrix(flat)
	draw_rect(Rect2(Vector2(u, u * 2 + _lift * 0.6), size), Color(0, 0, 0, 0.38), true)

	draw_set_transform_matrix(lifted)
	var back := PixelArt.back_texture()
	for i in range(stack_depth, 0, -1):
		draw_texture_rect(back, Rect2(Vector2(-u * i, -u * i), size), false, Color(0.75, 0.75, 0.75))

	var tint := Color(1, 1, 1, 1) if not dim else Color(0.62, 0.6, 0.62, 1.0)
	draw_texture_rect(_texture(), rect, false, tint)

	if burned:
		# Velo de humo suave (el número tiene que seguir leyéndose para poder
		# emparejarlo), marco de brasa y tizne en el borde superior.
		draw_rect(rect, Color(0.10, 0.06, 0.05, 0.34), true)
		_draw_frame(rect, Color(EMBER, 0.85), u)
		for i in range(int(size.x / u)):
			if i % 3 != 1:
				continue
			draw_rect(Rect2(i * u, u, u, u * 2), Color(0.08, 0.05, 0.04, 0.55), true)

	# Velo del bloqueo del tutorial, y sólo si la carta se podría pulsar: si se
	# oscurecieran también las que la partida ya tiene apagadas, durante el
	# tutorial la mesa entera saldría en penumbra.
	if locked and interactive:
		draw_rect(rect, Color(0.05, 0.03, 0.02, 0.45), true)

	if _glow > 0.01:
		_draw_frame(rect.grow(u), Color(GOLD, 0.35 + 0.55 * _glow), u)
	if selected:
		_draw_frame(rect.grow(u), GOLD, u)
	if timer_progress >= 0.0:
		var w: float = (size.x) * clamp(timer_progress, 0.0, 1.0)
		draw_rect(Rect2(0, size.y + u, size.x, u * 2), Color(0, 0, 0, 0.5), true)
		draw_rect(Rect2(0, size.y + u, w, u * 2), EMBER, true)

## Marco de grosor entero: cuatro rectángulos, nada de líneas suavizadas.
func _draw_frame(r: Rect2, color: Color, t: float) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - t), Vector2(r.size.x, t)), color, true)
	draw_rect(Rect2(r.position, Vector2(t, r.size.y)), color, true)
	draw_rect(Rect2(Vector2(r.end.x - t, r.position.y), Vector2(t, r.size.y)), color, true)
