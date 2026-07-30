class_name SmokeFx
extends Control
## SmokeFx.gd
## La humareda que sale de una carta al quemarla. Se crea sobre la capa de
## efectos, encima del descarte, y se borra sola cuando se apaga.
##
## Las volutas se dibujan como bloques de píxeles (dos rectángulos cruzados
## forman un octógono achaparrado) en vez de círculos suaves, para que el humo
## sea del mismo material que el resto del juego. Suben, se ensanchan, se
## desvían y se desvanecen; entre medias saltan pavesas naranjas que suben más
## deprisa y duran menos.

const SMOKE_TONES := [
	Color("#8a857c"), Color("#6e6a62"), Color("#55514a"), Color("#9d978c"),
]
const EMBER_TONES := [
	Color("#ffd36a"), Color("#ff8c3a"), Color("#e8b061"),
]

var _t: float = 0.0
var _life: float = 1.9
var _unit: float = 4.0
var _parts: Array = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_process(true)

## rect es el hueco de la carta en coordenadas de esta capa; unit, el tamaño de
## un píxel del juego, para que el humo tenga el mismo grano que las cartas.
func setup(rect: Rect2, unit: float) -> void:
	position = rect.position
	size = rect.size
	_unit = max(2.0, unit)
	for i in range(16):
		_parts.append({
			"kind": "smoke",
			"pos": Vector2(randf_range(0.1, 0.9) * rect.size.x, randf_range(0.25, 0.95) * rect.size.y),
			"vel": Vector2(randf_range(-14.0, 14.0), randf_range(-46.0, -22.0)),
			"r0": randf_range(0.8, 1.8) * _unit,
			"r1": randf_range(3.0, 6.5) * _unit,
			"born": randf() * 0.45,
			"life": randf_range(0.9, 1.5),
			"seed": randf() * TAU,
			"color": SMOKE_TONES[randi() % SMOKE_TONES.size()],
		})
	for i in range(10):
		_parts.append({
			"kind": "ember",
			"pos": Vector2(randf_range(0.15, 0.85) * rect.size.x, randf_range(0.4, 0.9) * rect.size.y),
			"vel": Vector2(randf_range(-26.0, 26.0), randf_range(-95.0, -50.0)),
			"r0": _unit,
			"r1": _unit,
			"born": randf() * 0.18,
			"life": randf_range(0.3, 0.6),
			"seed": randf() * TAU,
			"color": EMBER_TONES[randi() % EMBER_TONES.size()],
		})

func _process(delta: float) -> void:
	_t += delta
	if _t >= _life:
		queue_free()
		return
	queue_redraw()

## Voluta de humo: dos rectángulos cruzados dan un bloque con las esquinas
## comidas, que es como se dibuja una nube en pixel art.
func _blob(center: Vector2, r: float, color: Color) -> void:
	var u := _unit
	var rr: float = max(u, round(r / u) * u)
	var c := Vector2(round(center.x / u) * u, round(center.y / u) * u)
	if rr <= u:
		draw_rect(Rect2(c, Vector2(u, u)), color, true)
		return
	draw_rect(Rect2(c - Vector2(rr - u, rr), Vector2((rr - u) * 2.0, rr * 2.0)), color, true)
	draw_rect(Rect2(c - Vector2(rr, rr - u), Vector2(rr * 2.0, (rr - u) * 2.0)), color, true)

func _draw() -> void:
	for p in _parts:
		var age: float = _t - p.born
		if age < 0.0 or age > p.life:
			continue
		var u: float = age / p.life
		# Sube frenándose y se desvía en zigzag, como el humo de verdad.
		var pos: Vector2 = p.pos + p.vel * age * (1.0 - u * 0.45)
		pos.x += sin(_t * 2.2 + p.seed) * age * 9.0
		if p.kind == "ember":
			# Las pavesas no crecen: sólo se apagan.
			draw_rect(Rect2(Vector2(round(pos.x / _unit) * _unit, round(pos.y / _unit) * _unit),
				Vector2(_unit, _unit)), Color(p.color, (1.0 - u) * 0.95), true)
			continue
		var r: float = lerp(p.r0, p.r1, pow(u, 0.6))
		# Aparece deprisa y se disuelve despacio.
		var a: float = min(1.0, u * 5.0) * pow(1.0 - u, 1.5) * 0.55
		_blob(pos, r, Color(p.color, a))
